;; Channels

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
;;;; 
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Channel implementation following the 2009 ICFP paper "Parallel
;;; Concurrent ML" by John Reppy, Claudio V. Russo, and Yingqui Xiao.
;;;
;;; Besides the general ways in which this implementation differs from
;;; the paper, this channel implementation avoids locks entirely.
;;; Still, we should disable interrupts while any operation is in a
;;; "claimed" state to avoid excess latency due to pre-emption.  It
;;; would be great if we could verify our protocol though; the
;;; parallel channel operations are still gnarly.

(define-module (fibers channels)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 match)
  #:use-module (fibers internal)
  #:use-module (fibers operations)
  #:export (make-channel
            put-operation
            get-operation
            put-message
            get-message))


;; A functional double-ended queue ("deque") has a head and a tail,
;; which are both lists.  The head is in FIFO order and the tail is in
;; LIFO order.
(define-inlinable (make-deque head tail)
  (cons head tail))

(define (make-empty-deque)
  (make-deque '() '()))

(define (enqueue dq item)
  (match dq
    ((head . tail)
     (make-deque head (cons item tail)))))

(define (undequeue dq item)
  (match dq
    ((head . tail)
     (make-deque (cons item head) tail))))

;; -> new deque, val | #f, #f
(define (dequeue dq)
  (match dq
    ((() . ()) (values #f #f))
    ((() . tail)
     (dequeue (make-deque (reverse tail) '())))
    (((item . head) . tail)
     (values (make-deque head tail) item))))

(define (dequeue-match dq pred)
  (match dq
    ((() . ()) (values #f #f))
    ((() . tail)
     (dequeue (make-deque (reverse tail) '())))
    (((item . head) . tail)
     (if (pred item)
         (values (make-deque head tail) item)
         (call-with-values (dequeue-match (make-deque head tail) pred)
           (lambda (dq item*)
             (values (undequeue dq item) item*)))))))

(define (enqueue! qbox item)
  (let spin ((q (atomic-box-ref qbox)))
    (let* ((q* (enqueue q item))
           (q** (atomic-box-compare-and-swap! qbox q q*)))
      (unless (eq? q q**)
        (spin q**)))))

(define-record-type <channel>
  (%make-channel getq putq)
  channel?
  ;; atomic box of deque
  (getq channel-getq)
  ;; atomic box of deque
  (putq channel-putq))

(define (make-channel)
  (%make-channel (make-atomic-box (make-empty-deque))
                 (make-atomic-box (make-empty-deque))))

(define (put-operation channel msg)
  (match channel
    (($ <channel> getq-box putq-box)
     (define (try-fn)
       ;; Try to find and perform a pending get operation.  If that
       ;; works, return a result thunk, or otherwise #f.
       (let try ((getq (atomic-box-ref getq-box)))
         (call-with-values (lambda () (dequeue getq))
           (lambda (getq* item)
             (define (maybe-commit)
               ;; Try to update getq.  Return the new getq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! getq-box getq getq*)))
                 (if (eq? q getq) getq* getq)))
             ;; Return #f if the getq was empty.
             (and getq*
                  (match item
                    (#(get-flag get-fiber get-wrap-fn)
                     (let spin ()
                       (match (atomic-box-compare-and-swap! get-flag 'W 'S)
                         ('W
                          ;; Success.  Commit the dequeue operation,
                          ;; unless the getq changed in the
                          ;; meantime.  If we don't manage to commit
                          ;; the dequeue, some other put operation will
                          ;; commit it before it successfully
                          ;; performs any other operation on this
                          ;; channel.
                          (maybe-commit)
                          (resume-fiber get-fiber (if get-wrap-fn
                                                      (lambda ()
                                                        (get-wrap-fn msg))
                                                      (lambda () msg)))
                          ;; Continue directly.
                          (lambda () (values)))
                         ;; Get operation temporarily busy; try again.
                         ('C (spin))
                         ;; Get operation already performed; pop it
                         ;; off the getq (if we can) and try again.
                         ;; If we fail to commit, no big deal, we will
                         ;; try again next time if no other fiber
                         ;; handled it already.
                         ('S (try (maybe-commit))))))))))))
     (define (block-fn put-flag put-fiber put-wrap-fn)
       ;; We have suspended the current fiber; arrange for the fiber
       ;; to be resumed by a get operation by adding it to the channel's
       ;; putq.
       (define (not-me? item)
         (match item
           (#(get-flag get-fiber get-wrap-fn)
            (not (eq? put-flag get-flag)))))
       ;; First, publish this put operation.
       (enqueue! putq-box (vector put-flag put-fiber put-wrap-fn msg))
       ;; In the try phase, we scanned the getq for a get operation,
       ;; but we were unable to perform any of them.  Since then,
       ;; there might be a new get operation on the queue.  However
       ;; only get operations published *after* we publish our put
       ;; operation to the putq are responsible for trying to complete
       ;; this put operation; we are responsible for get operations
       ;; published before we published our put.  Therefore, here we
       ;; visit the getq again.  This is like the "try" phase, but
       ;; with the difference that we've published our op state flag
       ;; to the queue, so other fibers might be racing to synchronize
       ;; on our own op.
       (let service-get-ops ((getq (atomic-box-ref getq-box)))
         (call-with-values (lambda () (dequeue-match getq not-me?))
           (lambda (getq* item)
             (define (maybe-commit)
               ;; Try to update getq.  Return the new getq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! getq-box getq getq*)))
                 (if (eq? q getq) getq* getq)))
             ;; We only have to service the getq if it is non-empty.
             (when getq*
               (match item
                 (#(get-flag get-fiber get-wrap-fn)
                  (match (atomic-box-ref get-flag)
                    ('S
                     ;; This get operation has already synchronized;
                     ;; try to commit and  operation and in any
                     ;; case try again.
                     (service-get-ops (maybe-commit)))
                    (_
                     (let spin ()
                       (match (atomic-box-compare-and-swap! put-flag 'W 'C)
                         ('W
                          ;; We were able to claim our op.  Now try to
                          ;; synchronize on a get operation as well.
                          (match (atomic-box-compare-and-swap! get-flag 'W 'S)
                            ('W
                             ;; It worked!  Mark our own op as
                             ;; synchronized, try to commit the result
                             ;; getq, and resume both fibers.
                             (atomic-box-set! put-flag 'S)
                             (maybe-commit)
                             (resume-fiber get-fiber
                                           (if get-wrap-fn
                                               (lambda () (get-wrap-fn msg))
                                               (lambda () msg)))
                             (resume-fiber put-fiber (or put-wrap-fn values))
                             (values))
                            ('C
                             ;; Other fiber trying to do the same
                             ;; thing we are; reset our state and try
                             ;; again.
                             (atomic-box-set! put-flag 'W)
                             (spin))
                            ('S
                             ;; Other op already synchronized.  Reset
                             ;; our flag, try to remove this dead
                             ;; entry from the getq, and give it
                             ;; another go.
                             (atomic-box-set! put-flag 'W)
                             (service-get-ops (maybe-commit)))))
                         (_
                          ;; Claiming our own op failed; this can only
                          ;; mean that some other fiber completed our
                          ;; op for us.
                          (values)))))))))))))
     (make-base-operation #f try-fn block-fn))))

(define (get-operation channel)
  (match channel
    (($ <channel> getq-box putq-box)
     (define (try-fn)
       ;; Try to find and perform a pending put operation.  If that
       ;; works, return a result thunk, or otherwise #f.
       (let try ((putq (atomic-box-ref putq-box)))
         (call-with-values (lambda () (dequeue putq))
           (lambda (putq* item)
             (define (maybe-commit)
               ;; Try to update putq.  Return the new putq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! putq-box putq putq*)))
                 (if (eq? q putq) putq* putq)))
             ;; Return #f if the putq was empty.
             (and putq*
                  (match item
                    (#(put-flag put-fiber put-wrap-fn msg)
                     (let spin ()
                       (match (atomic-box-compare-and-swap! put-flag 'W 'S)
                         ('W
                          ;; Success.  Commit the fresh putq if we
                          ;; can.  If we don't manage to commit right
                          ;; now, some other get operation will commit
                          ;; it before synchronizing any other
                          ;; operation on this channel.
                          (maybe-commit)
                          (resume-fiber put-fiber (or put-wrap-fn values))
                          ;; Continue directly.
                          (lambda () msg))
                         ;; Put operation temporarily busy; try again.
                         ('C (spin))
                         ;; Put operation already synchronized; pop it
                         ;; off the putq (if we can) and try again.
                         ;; If we fail to commit, no big deal, we will
                         ;; try again next time if no other fiber
                         ;; handled it already.
                         ('S (try (maybe-commit))))))))))))
     (define (block-fn get-flag get-fiber get-wrap-fn)
       ;; We have suspended the current fiber; arrange for the fiber
       ;; to be resumed by a put operation by adding it to the
       ;; channel's getq.
       (define (not-me? item)
         (match item
           (#(put-flag put-fiber put-wrap-fn msg)
            (not (eq? get-flag put-flag)))))
       ;; First, publish this get operation.
       (enqueue! getq-box (vector get-flag get-fiber get-wrap-fn))
       ;; In the try phase, we scanned the putq for a live put
       ;; operation, but we were unable to synchronize.  Since then,
       ;; there might be a new operation on the putq.  However only
       ;; put operations published *after* we publish our get
       ;; operation to the getq are responsible for trying to complete
       ;; this get operation; we are responsible for put operations
       ;; published before we published our get.  Therefore, here we
       ;; visit the putq again.  This is like the "try" phase, but
       ;; with the difference that we've published our op state flag
       ;; to the getq, so other fibers might be racing to synchronize
       ;; on our own op.
       (let service-put-ops ((putq (atomic-box-ref putq-box)))
         (call-with-values (lambda () (dequeue-match putq not-me?))
           (lambda (putq* item)
             (define (maybe-commit)
               ;; Try to update putq.  Return the new putq value in
               ;; any case.
               (let ((q (atomic-box-compare-and-swap! putq-box putq putq*)))
                 (if (eq? q putq) putq* putq)))
             ;; We only have to service the putq if it is non-empty.
             (when putq*
               (match item
                 (#(put-flag put-fiber put-wrap-fn msg)
                  (match (atomic-box-ref put-flag)
                    ('S
                     ;; This put operation has already synchronized;
                     ;; try to commit the dequeue operation and in any
                     ;; case try again.
                     (service-put-ops (maybe-commit)))
                    (_
                     (let spin ()
                       (match (atomic-box-compare-and-swap! get-flag 'W 'C)
                         ('W
                          ;; We were able to claim our op.  Now try
                          ;; to synchronize on a put operation as well.
                          (match (atomic-box-compare-and-swap! put-flag 'W 'S)
                            ('W
                             ;; It worked!  Mark our own op as
                             ;; synchronized, try to commit the put
                             ;; dequeue operation, and mark both
                             ;; fibers for resumption.
                             (atomic-box-set! get-flag 'S)
                             (maybe-commit)
                             (resume-fiber get-fiber
                                           (if get-wrap-fn
                                               (lambda () (get-wrap-fn msg))
                                               (lambda () msg)))
                             (resume-fiber put-fiber (or put-wrap-fn values))
                             (values))
                            ('C
                             ;; Other fiber trying to do the same
                             ;; thing we are; reset our state and try
                             ;; again.
                             (atomic-box-set! get-flag 'W)
                             (spin))
                            ('S
                             ;; Put op already synchronized.  Reset
                             ;; get flag, try to remove this dead
                             ;; entry from the putq, and give it
                             ;; another go.
                             (atomic-box-set! get-flag 'W)
                             (service-put-ops (maybe-commit)))))
                         (_
                          ;; Claiming our own op failed; this can
                          ;; only mean that some other fiber
                          ;; completed our op for us.
                          (values)))))))))))))
     (make-base-operation #f try-fn block-fn))))

(define (put-message ch exp)
  (perform-operation (put-operation ch exp)))

(define (get-message ch)
  (perform-operation (get-operation ch)))
