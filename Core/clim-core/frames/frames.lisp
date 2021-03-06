;;; ---------------------------------------------------------------------------
;;;   License: LGPL-2.1+ (See file 'Copyright' for details).
;;; ---------------------------------------------------------------------------
;;;
;;;  (c) copyright 1998,1999,2000 by Michael McDonald (mikemac@mikemac.com)
;;;  (c) copyright 2000 by Iban Hatchondo (hatchond@emi.u-bordeaux.fr)
;;;  (c) copyright 2000 by Julien Boninfante (boninfan@emi.u-bordeaux.fr)
;;;  (c) copyright 2000, 2014 by Robert Strandh (robert.strandh@gmail.com)
;;;  (c) copyright 2004 by Gilbert Baumann <unk6@rz.uni-karlsruhe.de>
;;;  (c) copyright 2019, 2020 Jan Moringen <jmoringe@techfak.uni-bielefeld.de>
;;;
;;; ---------------------------------------------------------------------------
;;;
;;; Application frame classes and implementations of related protocol.
;;;

(in-package #:clim-internals)

;; *application-frame* is in decls.lisp
(defvar *default-frame-manager* nil)

;;; Frame-Manager class

;; FIXME: The spec says the port must "conform to options".  I've added a check
;; that the ports match, but we've no protocol for testing the other
;; options. -Hefner
(defun find-frame-manager (&rest options &key port &allow-other-keys)
  (declare (special *frame-manager*))
  (if (and (boundp '*frame-manager*)
           (or (null port) (eql port (port *frame-manager*))))
      *frame-manager*
      (if (and *default-frame-manager*
               (frame-manager-p *default-frame-manager*)
               (or (null port) (eql port (port *default-frame-manager*))))
          *default-frame-manager*
          (first (frame-managers (or port (apply #'find-port options)))))))

(defmacro with-frame-manager ((frame-manager) &body body)
  `(let ((*frame-manager* ,frame-manager))
     (declare (special *frame-manager*))
     (locally ,@body)))

(defvar *pane-realizer* nil)

(defmacro with-look-and-feel-realization ((frame-manager frame) &body body)
  `(let ((*pane-realizer* ,frame-manager)
         (*application-frame* ,frame))
     (locally
         ,@body)))

(defun map-over-frames (function &key port frame-manager)
  (cond (frame-manager
         (mapc function (frame-manager-frames frame-manager)))
        (port
         (loop for manager in (frame-managers port)
               do (map-over-frames function :frame-manager manager)))
        (t (loop for p in *all-ports*
                 do (map-over-frames function :port p)))))

(defmethod note-frame-enabled ((fm frame-manager) frame)
  (declare (ignore frame))
  t)

(defmethod note-frame-disabled ((fm frame-manager) frame)
  (declare (ignore frame))
  t)

(defmethod note-frame-iconified ((fm frame-manager) frame)
  (declare (ignore frame))
  t)

(defmethod note-frame-deiconified ((fm frame-manager) frame)
  (declare (ignore frame))
  t)

;;; XXX These should force the redisplay of the menu bar. They don't yet.

(defmethod note-command-enabled (frame-manager frame command-name)
  (declare (ignore frame-manager frame command-name))
  nil)

(defmethod note-command-disabled (frame-manager frame command-name)
  (declare (ignore frame-manager frame command-name))
  nil)

(declaim (type (or null pattern) *default-icon-large* *default-icon-small*))
(defvar *default-icon-large* nil)
(defvar *default-icon-small* nil)

(defclass standard-application-frame (application-frame
                                      presentation-history-mixin)
  ((port :initform nil
         :initarg :port
         :accessor port)
   (graft :initform nil
          :initarg :graft
          :accessor graft)
   (name :initarg :name
         :reader frame-name)
   (pretty-name :initarg :pretty-name
                :accessor frame-pretty-name)
   (icon :accessor frame-icon
         :documentation "If non-NIL, an array pattern or a sequence
                         of array patterns that should be used by the
                         host's window manager to represent the
                         frame, for example when it is iconified.")
   (command-table :initarg :command-table
                  :initform nil
                  :accessor frame-command-table)
   (panes :initform nil :accessor frame-panes
          :documentation "The tree of panes in the current layout.")
   (current-panes :initform nil :accessor frame-current-panes)
   (layouts :initform nil
            :initarg :layouts
            :reader frame-layouts)
   (current-layout :initform nil
                   :initarg :current-layout
                   :accessor frame-current-layout)
   (panes-for-layout :initform nil :accessor frame-panes-for-layout
                     :documentation "alist of names and panes
                                     (as returned by make-pane)")
   (resize-frame :initarg :resize-frame
                 :initform nil
                 :accessor frame-resize-frame)
   (output-pane :initform nil
                :accessor frame-standard-output
                :accessor frame-error-output)
   (input-pane :initform nil
               :accessor frame-standard-input)
   (documentation-pane :initform nil
                       :accessor frame-pointer-documentation-output)

   (top-level-sheet :initform nil
                    :reader frame-top-level-sheet)
   (menu-bar :initarg :menu-bar
             :initform nil)
   (menu-bar-pane :initform nil
                  :accessor frame-menu-bar-pane)
   (state :initarg :state
          :initform :disowned
          :reader frame-state)
   (manager :initform nil
            :reader frame-manager
            :accessor %frame-manager)
   (properties :accessor %frame-properties
               :initarg :properties
               :initform nil)
   (top-level :initform '(default-frame-top-level)
              :initarg :top-level
              :reader frame-top-level)
   (top-level-lambda :initarg :top-level-lambda
                     :reader frame-top-level-lambda)
   (highlited-presentation :initform nil
                           :initarg :highlited-presentation
                           :accessor frame-highlited-presentation)
   (process :accessor frame-process :initform nil)
   (client-settings :accessor client-settings :initform nil)
   (event-queue :initarg :frame-event-queue
                :initform nil
                :accessor frame-event-queue
                :documentation "The event queue that, by default, will be
                                shared by all panes in the frame")
   (input-buffer :initarg :frame-input-buffer
                 :initform (make-instance 'concurrent-event-queue :port nil)
                 :accessor frame-input-buffer
                 :documentation "The input buffer queue that, by default, will
                                 be shared by all input streams in the frame")
   ;; This slot is true during the execution of the FRAME-READ-COMMAND. It is
   ;; used by the EXECUTE-FRAME-COMMAND to decide, whether the synchronous[1]
   ;; command execution should be performed immedietely or enqueued in the
   ;; event queue. This is to ensure advancement of the top level loop and
   ;; redisplay of panes after the command execution.
   ;;
   ;; The frame-command-queue is used to schedule a command for the next
   ;; iteration of the frame top level when the input context inside the call
   ;; to FRAME-READ-COMMAND is different than the command (that may happen i.e
   ;; when the frame has a temporarily amended command table or is waiting for
   ;; an argument of the command that is currently parsed).
   ;;
   ;; [1] A synchronous execution is a call of the EXECUTE-FRAME-COMMAND in
   ;; the frame's process.
   ;;
   ;; -- jd 2020-12-10
   (reading-command-p :initform nil
                      :accessor frame-reading-command-p)
   (command-queue :initform (make-instance 'concurrent-event-queue :port nil)
                  :reader frame-command-queue)
   (documentation-state :accessor frame-documentation-state
                        :initform nil
                        :documentation "Used to keep of track of what
  needs to be rendered in the pointer documentation frame.")
   (calling-frame :reader frame-calling-frame
                  :initarg :calling-frame
                  :initform nil
                  :documentation "The frame that is the parent of this
frame, if any")
   (disabled-commands :accessor disabled-commands
                      :accessor frame-disabled-commands
                      :initarg :disabled-commands
                      :initform nil
                      :documentation "A list of command names that have been
                                      disabled in this frame")
   (documentation-record :accessor documentation-record
                         :initform nil
                         :documentation "updating output record for pointer
documentation produced by presentations.")
   (geometry-left :accessor geometry-left
                  :initarg :left
                  :initform nil)
   (geometry-right :accessor geometry-right
                   :initarg :right
                   :initform nil)
   (geometry-top :accessor geometry-top
                 :initarg :top
                 :initform nil)
   (geometry-bottom :accessor geometry-bottom
                    :initarg :bottom
                    :initform nil)
   (geometry-width :accessor geometry-width
                   :initarg :width
                   :initform nil)
   (geometry-height :accessor geometry-height
                    :initarg :height
                    :initform nil)))

(defmethod frame-parent ((frame standard-application-frame))
  (or (frame-calling-frame frame)
      (frame-manager frame)))

(defmethod frame-query-io ((frame standard-application-frame))
  (or (frame-standard-input frame)
      (frame-standard-output frame)))

(defgeneric frame-geometry* (frame))

(defmethod frame-geometry* ((frame standard-application-frame))
  "-> width height &optional top left"
  (let ((pane (frame-top-level-sheet frame)))
    ;(destructuring-bind (&key left top right bottom width height) (frame-geometry frame)
    (with-slots (geometry-left geometry-top geometry-right
                               geometry-bottom geometry-width
                               geometry-height) frame
      ;; Find width and height from looking at the respective options
      ;; first, then at left/right and top/bottom and finally at what
      ;; compose-space says.
      (let* ((width (or geometry-width
                        (and geometry-left geometry-right
                             (- geometry-right geometry-left))
                        (space-requirement-width (compose-space pane))))
             (height (or geometry-height
                         (and geometry-top geometry-bottom (- geometry-bottom geometry-top))
                         (space-requirement-height (compose-space pane))))
             ;; See if a position is wanted and return left, top.
             (left (or geometry-left
                       (and geometry-right (- geometry-right geometry-width))))
             (top (or geometry-top
                      (and geometry-bottom (- geometry-bottom geometry-height)))))
      (values width height left top)))))

;;; This method causes related frames share the same queue by default (on both
;;; SMP and non-SMP systems). Thanks to that we have a single loop processing
;;; events. Alternative approach is executed with window-stream frames which
;;; have a standalone-event-loop (see panes.lisp). -- jd 2018-12-27
(defmethod initialize-instance :after ((obj standard-application-frame)
                                       &key (icon nil icon-supplied-p)
                                       &allow-other-keys)
  (labels ((coerce-to-icon (thing)
             (typecase thing
               ((or string pathname)
                (make-pattern-from-bitmap-file thing))
               (sequence
                (map 'list #'coerce-to-icon thing))
               (t
                thing))))
    (setf (slot-value obj 'icon)
          (cond ((not icon-supplied-p)
                 (remove nil (list *default-icon-large* *default-icon-small*)))
                ((null icon)
                 nil)
                (t
                 (coerce-to-icon icon)))))
  (unless (frame-event-queue obj)
    (when-let* ((calling-frame (frame-calling-frame obj))
                (calling-queue (frame-event-queue calling-frame)))
      (setf (frame-event-queue obj) calling-queue)
      (return-from initialize-instance))
    (setf (frame-event-queue obj)
          (if *multiprocessing-p*
              (make-instance 'concurrent-event-queue)
              (make-instance 'simple-event-queue)))))

(defmethod (setf frame-manager) (fm (frame application-frame))
  (let ((old-manager (frame-manager frame)))
    (setf (%frame-manager frame) nil)
    (when old-manager
      (disown-frame old-manager frame)
      (setf (frame-panes frame) nil)
      (setf (slot-value frame 'layouts) nil))
    (setf (%frame-manager frame) fm)))

(defmethod (setf frame-pretty-name) :after (new-value frame)
  ;; If there is a top-level sheet, set its pretty name. The port can
  ;; reflect this change in the window title.
  (when-let ((top-level-sheet (frame-top-level-sheet frame)))
    (setf (sheet-pretty-name top-level-sheet) new-value))
  ;; Let client code know.
  (clime:note-frame-pretty-name-changed (frame-manager frame) frame new-value))

(defmethod (setf frame-icon) :after (new-value frame)
  ;; If there is a top-level sheet, set its icon. The port can reflect
  ;; this change by telling the window manager which might display the
  ;; new icon somewhere.
  (when-let ((top-level-sheet (frame-top-level-sheet frame)))
    (setf (sheet-icon top-level-sheet) new-value))
  ;; Let client code know.
  (note-frame-icon-changed (frame-manager frame) frame new-value))

(defmethod frame-all-layouts ((frame application-frame))
  (mapcar #'car (frame-layouts frame)))

(define-condition frame-layout-changed (condition)
  ((frame :initarg :frame :reader frame-layout-changed-frame)))

(defmethod (setf frame-current-layout) :around (name (frame application-frame))
  (unless (eql name (frame-current-layout frame))
    (call-next-method)
    (when-let ((fm (frame-manager frame)))
      (if-let ((tls (and (frame-resize-frame frame)
                         (frame-top-level-sheet frame))))
        (multiple-value-bind (width height)
            (bounding-rectangle-size tls)
          (generate-panes fm frame)
          (layout-frame frame width height))
        (progn
          (generate-panes fm frame)
          (layout-frame frame)))
      (signal 'frame-layout-changed :frame frame))))

(defmethod (setf frame-command-table) :after (new-command-table frame)
  ;; Update the menu-bar even if its command-table doesn't change to ensure
  ;; that disabled commands are not active (and vice versa). -- jd 2020-12-12
  (when-let ((bar-command-table (slot-value frame 'menu-bar)))
    (if (eq bar-command-table t)
        (update-menu-bar (frame-menu-bar-pane frame) frame new-command-table)
        (update-menu-bar (frame-menu-bar-pane frame) frame bar-command-table))))

(defun update-frame-pane-lists (frame)
  (let ((all-panes     (frame-panes frame))
        (named-panes   (mapcar #'cdr (frame-panes-for-layout frame)))
        (current-panes '()))
    ;; Find intersection of named panes and current layout panes.
    (map-over-sheets (lambda (sheet)
                       (when-let ((index (position sheet named-panes)))
                         (push (cons sheet index) current-panes)))
                     all-panes)
    (setf current-panes (mapcar #'car (sort current-panes #'< :key #'cdr)))
    ;; Populate current-pane list and special pane slots.
    (let ((interactor            (find-pane-of-type current-panes 'interactor-pane))
          (application           (find-pane-of-type current-panes 'application-pane))
          (pointer-documentation (find-pane-of-type all-panes 'pointer-documentation-pane)))
      (setf (frame-current-panes frame) current-panes
            (frame-standard-output frame) (or application interactor)
            (frame-standard-input frame) (or interactor (frame-standard-output frame))
            (frame-pointer-documentation-output frame) pointer-documentation))))

(defmethod generate-panes :before (fm  (frame application-frame))
  (declare (ignore fm))
  (when (and (frame-panes frame)
             (eq (sheet-parent (frame-panes frame))
                 (frame-top-level-sheet frame)))
    (sheet-disown-child (frame-top-level-sheet frame) (frame-panes frame)))
  (loop for (nil . pane) in (frame-panes-for-layout frame)
        for parent = (sheet-parent pane)
        if  parent
        do (sheet-disown-child parent pane)))

(defmethod generate-panes (fm (frame application-frame))
  (with-look-and-feel-realization (fm frame)
    (unless (frame-panes-for-layout frame)
      (setf (frame-panes-for-layout frame)
            `((single-pane . ,(make-clim-interactor-pane :name 'single-pane)))))
    (let ((single-pane
            (alexandria:assoc-value (frame-panes-for-layout frame)
                                    'single-pane :test #'eq)))
      (setf (frame-panes frame) single-pane)))
  (update-frame-pane-lists frame))

(defmethod generate-panes :after (fm (frame application-frame))
  (declare (ignore fm))
  (let ((top-level-sheet (frame-top-level-sheet frame)))
    (sheet-adopt-child top-level-sheet (frame-panes frame))
    (unless (sheet-parent top-level-sheet)
      (sheet-adopt-child (graft frame) top-level-sheet))
    ;; Find the size of the new frame
    (multiple-value-bind (w h) (frame-geometry* frame)
      ;; automatically generates a window-configuation-event
      ;; which then calls allocate-space
      ;;
      ;; Not any longer, we turn off CONFIGURE-NOTIFY events until the
      ;; window is mapped and do the space allocation now, so that all
      ;; sheets will have their correct geometry at once. --GB
      (change-space-requirements top-level-sheet :width w :height h
                                                 :resize-frame t)
      (setf (sheet-region top-level-sheet) (make-bounding-rectangle 0 0 w h))
      (allocate-space top-level-sheet w h))))

(defmethod layout-frame ((frame application-frame) &optional width height)
  (when (and (or width height)
             (not (and width height)))
    (error "LAYOUT-FRAME must be called with both WIDTH and HEIGHT or neither"))
  (with-inhibited-dispatch-repaint ()
    (let ((pane (frame-panes frame)))
      (when (and (null width) (null height))
        (let (;;I guess this might be wrong. --GB 2004-06-01
              (space (compose-space pane)))
          (setq width (space-requirement-width space))
          (setq height (space-requirement-height space))))
      (let ((tpl-sheet (frame-top-level-sheet frame)))
        (unless (and (= width (bounding-rectangle-width tpl-sheet))
                     (= height (bounding-rectangle-height tpl-sheet)))
          (resize-sheet tpl-sheet width height)))
      (allocate-space pane width height))))

(defun find-pane-of-type (parent type)
  "Returns a pane of `type' in the forest growing from `parent'."
  (map-over-sheets #'(lambda (p)
                       (when (typep p type)
                         (return-from find-pane-of-type p)))
                   parent)
  nil)

(defmethod get-frame-pane ((frame application-frame) pane-name)
  (let ((pane (find-pane-named frame pane-name)))
    (if (typep pane 'clim-stream-pane)
        pane
        nil)))

(defmethod find-pane-named ((frame application-frame) pane-name)
  (map-over-sheets #'(lambda (p)
                       (when (eql pane-name (pane-name p))
                         (return-from find-pane-named p)))
                   (frame-panes frame))
  nil)


#+nil
(defmethod redisplay-frame-panes ((frame application-frame) &key force-p)
  (map-over-sheets
   (lambda (sheet)
     (when (typep sheet 'pane)
       (when (and (typep sheet 'clim-stream-pane)
                  (not (eq :no-clear (pane-redisplay-needed sheet))))
         (window-clear sheet))
       (redisplay-frame-pane frame sheet :force-p force-p)))
   (frame-top-level-sheet frame)))

(defmethod redisplay-frame-panes ((frame application-frame) &key force-p)
  (map-over-sheets (lambda (sheet)
                     (when (sheet-viewable-p sheet)
                       (redisplay-frame-pane frame sheet :force-p force-p)))
                   (frame-top-level-sheet frame)))

(defmethod frame-replay (frame stream &optional region)
  (declare (ignore frame))
  (stream-replay stream region))

(defmethod frame-properties ((frame application-frame) property)
  (getf (%frame-properties frame) property))

(defmethod (setf frame-properties) (value (frame application-frame) property)
  (setf (getf (%frame-properties frame) property) value))

;;; Command loop interface

(define-condition frame-exit (condition)
  ((frame :initarg :frame :reader frame-exit-frame)
   (handled :accessor %frame-exit-handled :initform nil)))

(defmethod frame-exit ((frame standard-application-frame))
  (signal 'frame-exit :frame frame))

(defmethod redisplay-frame-pane ((frame application-frame) pane &key force-p)
  (declare (ignore pane force-p))
  nil)

(defmacro with-possible-double-buffering ((frame pane) &body body)
  `(progn ,@body))

(defmethod redisplay-frame-pane :around ((frame application-frame) pane
                                         &key force-p)
  (let ((pane-object (if (typep pane 'pane)
                         pane
                         (find-pane-named frame pane))))
    (restart-case
        (multiple-value-bind (redisplayp clearp)
            (pane-needs-redisplay pane-object)
          (when force-p
            (setq redisplayp (or redisplayp t)
                  clearp t))
          (when redisplayp
            (when-let ((highlited (frame-highlited-presentation frame)))
              (highlight-presentation-1 (car highlited)
                                        (cdr highlited)
                                        :unhighlight)
              (setf (frame-highlited-presentation frame) nil))
            (with-possible-double-buffering (frame pane-object)
              (when clearp
                (window-clear pane-object))
              (call-next-method))
            (unless (or (eq redisplayp :command-loop) (eq redisplayp :no-clear))
              (setf (pane-needs-redisplay pane-object) nil))))
      (clear-pane-try-again ()
       :report "Clear the output history of the pane and reattempt forceful redisplay."
       (window-clear pane)
       (redisplay-frame-pane frame pane :force-p t))
      (clear-pane ()
       :report "Clear the output history of the pane, but don't redisplay."
       (window-clear pane))
      (skip-redisplay ()
       :report "Skip this redisplay."))))

(defmethod run-frame-top-level ((frame application-frame)
                                &key &allow-other-keys)
  (letf (((frame-process frame) (current-process)))
    (funcall (frame-top-level-lambda frame) frame)))

(defmethod run-frame-top-level :around ((frame application-frame) &key)
  (let ((*application-frame* frame)
        (*input-context* nil)
        (*input-wait-test* nil)
        (*input-wait-handler* nil)
        (*pointer-button-press-handler* nil)
        (original-state (frame-state frame)))
    (declare (special *input-context* *input-wait-test* *input-wait-handler*
                      *pointer-button-press-handler*))
    (when (eq (frame-state frame) :disowned) ; Adopt frame into frame manager
      (adopt-frame (or (frame-manager frame) (find-frame-manager))
                   frame))
    (unless (or (eq (frame-state frame) :enabled)
                (eq (frame-state frame) :shrunk))
      (enable-frame frame))
    (unwind-protect
         (loop named run-frame-loop
               for query-io = (frame-query-io frame)
               for *default-frame-manager* = (frame-manager frame)
               do (block run-frame-iter
                    (handler-bind
                        ((frame-layout-changed
                           (lambda (condition)
                             (declare (ignore condition))
                             (return-from run-frame-iter)))
                         (frame-exit
                           (lambda (condition)
                             (unless (%frame-exit-handled condition)
                               (setf (%frame-exit-handled condition) t)
                               (let ((exiting-frame (frame-exit-frame condition)))
                                 (if (eq exiting-frame frame)
                                     (return-from run-frame-loop)
                                     (disown-frame (frame-manager exiting-frame)
                                                   exiting-frame)))))))
                      (return-from run-frame-loop
                        (if query-io
                            (with-input-focus (query-io)
                              (call-next-method))
                            (call-next-method))))))
      (case original-state
        (:disabled
         (disable-frame frame))
        (:disowned
         (when-let ((fm (frame-manager frame)))
           (disown-frame fm frame)))))))

(defparameter +default-prompt-style+ (make-text-style :sans-serif :bold :normal))

(defmethod default-frame-top-level
    ((frame application-frame)
     &key (command-parser 'command-line-command-parser)
          (command-unparser 'command-line-command-unparser)
          (partial-command-parser
           'command-line-read-remaining-arguments-for-partial-command)
          (prompt "Command: "))
  ;; Give each pane a fresh start first time through.
  (let ((needs-redisplay t)
        (first-time t))
    (loop
      ;; The variables are rebound each time through the loop because the
      ;; values of frame-standard-input et al. might be changed by a command.
      ;;
      ;; We rebind *QUERY-IO* ensuring variable is always a stream,
      ;; but we use FRAME-QUERY-IO for our own actions and to decide
      ;; whenever frame has the query IO stream associated with it..
      (let* ((frame-query-io (frame-query-io frame))
             (interactorp (typep frame-query-io 'interactor-pane))
             (*standard-input*  (or (frame-standard-input frame)  *standard-input*))
             (*standard-output* (or (frame-standard-output frame) *standard-output*))
             (*query-io* (or frame-query-io *query-io*))
             ;; during development, don't alter *error-output*
             ;; (*error-output* (frame-error-output frame))
             (*pointer-documentation-output* (frame-pointer-documentation-output frame))
             (*command-parser* command-parser)
             (*command-unparser* command-unparser)
             (*partial-command-parser* partial-command-parser))
        (restart-case
            (flet ((execute-command ()
                     (when-let ((command (read-frame-command frame :stream frame-query-io)))
                       (setq needs-redisplay t)
                       (execute-frame-command frame command))))
              (when needs-redisplay
                (redisplay-frame-panes frame :force-p first-time)
                (setq first-time nil
                      needs-redisplay nil))
              (when interactorp
                (setf (cursor-visibility (stream-text-cursor frame-query-io)) nil)
                (when prompt
                  (with-text-style (frame-query-io +default-prompt-style+)
                    (if (stringp prompt)
                        (write-string prompt frame-query-io)
                        (funcall prompt frame-query-io frame))
                    (force-output frame-query-io))))
              (execute-command)
              (when interactorp
                (fresh-line frame-query-io)))
          (abort ()
            :report "Return to application command loop."
            (if interactorp
                (format frame-query-io "~&Command aborted.~&")
                (beep))))))))

(defmethod read-frame-command :around
    ((frame application-frame) &key (stream *standard-input*))
  (declare (ignore stream))
  (or (event-queue-read-no-hang (frame-command-queue frame))
      (letf (((frame-reading-command-p frame) t))
        (call-next-method))))

(defmethod read-frame-command ((frame application-frame)
                               &key (stream *standard-input*))
  ;; The following is the correct interpretation according to the spec.  I
  ;; think it is terribly counterintuitive and want to look into what existing
  ;; CLIMs do before giving in to it.  If we do things as the spec says,
  ;; command accelerators will appear to not work, confusing new users.
  #+(or)
  (read-command (frame-command-table frame) :use-keystrokes nil :stream stream)
  (if stream
      (read-command (frame-command-table frame) :use-keystrokes t :stream stream)
      (simple-event-loop frame)))

(define-event-class execute-command-event (window-manager-event)
  ((sheet :initarg :sheet :reader event-sheet)
   (frame :initarg :frame :reader execute-command-event-frame)
   (command :initarg :command :reader execute-command-event-command)))

(defmethod handle-event ((sheet top-level-sheet-mixin)
                         (event execute-command-event))
  (let* ((command (execute-command-event-command event))
         (frame (execute-command-event-frame event))
         (table (frame-command-table frame))
         (ptype `(command :command-table ,table)))
    (when (eq frame *application-frame*)
      (throw-object-ptype command ptype :sheet sheet))
    ;; We could have gotten here because:
    ;;
    ;; 1) a frame is not the *application-frame*, or
    ;; 2) throw-object-ptype did not match the existing input context.
    ;;
    ;; In both cases executing the command is not immedietely possible, so we
    ;; enqueue the command for EXECUTE-FRAME-COMMAND to pick it up during the
    ;; next iteration. -- jd 2020-12-09
    (event-queue-append (frame-command-queue frame) command)))

(defmethod execute-frame-command ((frame application-frame) command)
  (check-type command cons)
  (if (and (eq (frame-process frame) (current-process))
           (not (frame-reading-command-p frame)))
      (let ((name (command-name command))
            (args (command-arguments command)))
        (restart-case (apply name args)
          (try-again ()
            :report (lambda (stream)
                      (format stream "Try executing the command ~S again." name))
            (execute-frame-command frame command))))
      (let* ((sheet (frame-top-level-sheet frame))
             (queue (sheet-event-queue sheet)))
        (event-queue-append queue (make-instance 'execute-command-event
                                                 :sheet sheet
                                                 :frame frame
                                                 :command command)))))

(defmethod command-enabled (command-name (frame standard-application-frame))
  (and (command-accessible-in-command-table-p command-name
                                              (frame-command-table frame))
       (not (member command-name (disabled-commands frame)))))

(defmethod (setf command-enabled)
    (enabled command-name (frame standard-application-frame))
  (unless (command-accessible-in-command-table-p command-name
                                                 (frame-command-table frame))
    (return-from command-enabled nil))
  (with-accessors ((disabled-commands disabled-commands))
      frame
    (if enabled
        (progn
          (setf disabled-commands (delete command-name disabled-commands))
          (note-command-enabled (frame-manager frame)
                                frame
                                command-name)
          enabled)
        (progn
          (pushnew command-name disabled-commands)
          (note-command-disabled (frame-manager frame)
                                 frame
                                 command-name)
          nil))))

(defmethod display-command-menu (frame (stream fundamental-output-stream)
                                 &rest args &key
                                 (command-table (frame-command-table frame))
                                 initial-spacing row-wise max-width
                                 max-height n-rows n-columns
                                 (cell-align-x :left) (cell-align-y :top))
  (declare (ignore initial-spacing row-wise max-width max-height
                   n-rows n-columns cell-align-x cell-align-y))
  (with-keywords-removed (args (:command-table))
    (apply #'display-command-table-menu command-table stream args)))

(defmethod make-pane-1 :around (fm (frame standard-application-frame) type
                                &rest args
                                &key (event-queue nil evq-p) &allow-other-keys)
  ;; Default event-queue to the frame event queue.
  (declare (ignore event-queue))
  (if (null evq-p)
      (let ((evq (frame-event-queue frame))
            (*input-buffer* (frame-input-buffer frame)))
        (apply #'call-next-method fm frame type :event-queue evq args))
      (call-next-method)))

(defmethod find-pane-for-frame ((fm frame-manager) (frame application-frame))
  (make-pane-1 fm frame 'top-level-sheet-pane
               :name (frame-name frame)
               :pretty-name (frame-pretty-name frame)
               :icon (frame-icon frame)
               ;; sheet is enabled from enable-frame
               :enabled-p nil))

(defmethod adopt-frame ((fm frame-manager) (frame application-frame))
  (setf (slot-value fm 'frames) (cons frame (slot-value fm 'frames)))
  (setf (frame-manager frame) fm)
  (setf (port frame) (port fm))
  (setf (graft frame) (find-graft :port (port frame)))
  (let ((*application-frame* frame)
        (event-queue (frame-event-queue frame)))
    (setf (slot-value frame 'top-level-sheet)
          (find-pane-for-frame fm frame))
    (generate-panes fm frame)
    (setf (slot-value frame 'state) :disabled)
    (when (typep event-queue 'event-queue)
      (setf (event-queue-port event-queue) (port fm)))
    frame))

(defmethod disown-frame ((fm frame-manager) (frame application-frame))
  (when-let* ((event-queue (frame-event-queue frame))
              (calling-frame (frame-calling-frame frame))
              (calling-queue (frame-event-queue calling-frame))
              (another-queue-p (not (eql calling-queue event-queue))))
    (setf (event-queue-port event-queue) nil))
  (setf (slot-value fm 'frames) (remove frame (slot-value fm 'frames)))
  (sheet-disown-child (graft frame) (frame-top-level-sheet frame))
  (setf (%frame-manager frame) nil)
  (setf (slot-value frame 'state) :disowned)
  frame)

(defmethod enable-frame ((frame application-frame))
  (ecase (slot-value frame 'state)
    (:disabled
     (setf (sheet-enabled-p (frame-top-level-sheet frame)) t)
     (note-frame-enabled (frame-manager frame) frame))
    (:shrunk
     (setf (sheet-enabled-p (frame-top-level-sheet frame)) t)
     (note-frame-deiconified (frame-manager frame) frame))
    (:enabled))
  (setf (slot-value frame 'state) :enabled))

(defmethod disable-frame ((frame application-frame))
  (let ((top-level-sheet (frame-top-level-sheet frame)))
    (setf (sheet-enabled-p top-level-sheet) nil))
  (setf (slot-value frame 'state) :disabled)
  (note-frame-disabled (frame-manager frame) frame))

(defmethod shrink-frame ((frame application-frame))
  (unless (eq (slot-value frame 'state) :disabled)
    (shrink-sheet (frame-top-level-sheet frame))
    (setf (slot-value frame 'state) :shrunk)
    (note-frame-iconified (frame-manager frame) frame))
  (frame-state frame))

(defmethod destroy-frame ((frame application-frame))
  (when (eq (frame-state frame) :enabled)
    (disable-frame frame))
  (disown-frame (frame-manager frame) frame))

(defmethod raise-frame ((frame application-frame))
  (raise-sheet (frame-top-level-sheet frame)))

(defmethod bury-frame ((frame application-frame))
  (bury-sheet (frame-top-level-sheet frame)))

(defun make-application-frame (frame-name
                               &rest options
                               &key (frame-manager nil frame-manager-p)
                                    enable
                                    (state nil state-supplied-p)
                                    save-under (frame-class frame-name)
                               &allow-other-keys)
  (declare (ignore save-under))
  (with-keywords-removed (options (:frame-manager :enable :state
                                   :save-under :frame-class))
    (let ((frame (apply #'make-instance frame-class
                        :name frame-name
                        options)))
      (when frame-manager-p
        (adopt-frame frame-manager frame))
      (cond ((or enable (eq state :enabled))
             (enable-frame frame))
            ((and (eq state :disowned)
                  (not (eq (frame-state frame) :disowned)))
             (disown-frame (frame-manager frame) frame))
            (state-supplied-p
             (warn ":state ~S not supported yet." state)))
      frame)))

(defgeneric clim-extensions:find-frame-type (frame)
  (:method ((frame t))
    nil)
  (:documentation "Returns the type of the given frame. The return value of this
function can be used by the frame manager to determine the behaviour
of the frame.

This function should never be called by application code. Instead, the
application should define a method for this function that returns the
appropriate value for a frame.

The following values are currently supported by the CLX backend:

NIL - Default frame behaviour.

:OVERRIDE-REDIRECT - The frame will be displayed in front of all other
frames and will not have focus.

:DIALOG - The frame will not have any decorations added by the window manager."))

;;; From Franz Users Guide

(defun find-application-frame (frame-name &rest initargs
                               &key (create t) (activate t)
                               (own-process *multiprocessing-p*) port
                               frame-manager frame-class
                               &allow-other-keys)
  (declare (ignorable frame-class))
  (let ((frame (unless (eq create :force)
                 (block
                     found-frame
                   (map-over-frames
                    #'(lambda (frame)
                        (when (eq (frame-name frame) frame-name)
                          (return-from found-frame frame)))
                    :port port
                    :frame-manager frame-manager)))))
    (unless (or frame create)
      (return-from find-application-frame nil))
    (unless frame
      (with-keywords-removed (initargs (:create :activate :own-process))
        (setq frame (apply #'make-application-frame frame-name initargs))))
    (when (and frame activate)
      (cond ((frame-process frame)
             (raise-frame frame))
            (own-process
             (clim-sys:make-process #'(lambda ()
                                        (run-frame-top-level frame))
                                    :name (format nil "~A" frame-name)))
            (t (run-frame-top-level frame))))
    frame))

;;; Menu frame class

(defclass menu-frame ()
  ((left :initform 0 :initarg :left)
   (top :initform 0 :initarg :top)
   (min-width :initform nil :initarg :min-width)
   (top-level-sheet :initform nil :reader frame-top-level-sheet)
   (panes :reader frame-panes :initarg :panes)
   (graft :initform nil :accessor graft)
   (state :initarg :state
          :initform :disowned
          :reader frame-state)
   (manager :initform nil :accessor frame-manager)))

(defclass menu-unmanaged-top-level-sheet-pane (unmanaged-top-level-sheet-pane)
  ())

(defmethod adopt-frame ((fm frame-manager) (frame menu-frame))
  (setf (slot-value fm 'frames) (cons frame (slot-value fm 'frames)))
  (setf (frame-manager frame) fm)
  (let* ((t-l-s (make-pane-1 fm *application-frame*
                             'menu-unmanaged-top-level-sheet-pane
                             :name 'top-level-sheet
                             ;; enabling should be left to enable-frame
                             :enabled-p nil)))
    (setf (slot-value frame 'top-level-sheet) t-l-s)
    (sheet-adopt-child t-l-s (frame-panes frame))
    (let ((graft (find-graft :port (port fm))))
      (sheet-adopt-child graft t-l-s)
      (setf (graft frame) graft))
    (let ((pre-space (compose-space t-l-s))
          (frame-min-width (slot-value frame 'min-width)))
      (multiple-value-bind (width min-width max-width height min-height max-height)
          (space-requirement-components pre-space)
        (flet ((foomax (x y) (max (or x 1) (or y 1))))
          (let ((space (make-space-requirement :min-width  (foomax frame-min-width min-width)
                                               :width      (foomax frame-min-width width)
                                               :max-width  (foomax frame-min-width max-width)
                                               :min-height min-height
                                               :height     height
                                               :max-height max-height)))
            (allocate-space (frame-panes frame)
                            (space-requirement-width space)
                            (space-requirement-height space))
            (setf (sheet-region t-l-s)
                  (make-bounding-rectangle 0 0
                                           (space-requirement-width space)
                                           (space-requirement-height space))))
          (setf (sheet-transformation t-l-s)
                (make-translation-transformation (slot-value frame 'left)
                                                 (slot-value frame 'top))))))))

(defmethod disown-frame ((fm frame-manager) (frame menu-frame))
  (setf (slot-value fm 'frames) (remove frame (slot-value fm 'frames)))
  (let ((tps (frame-top-level-sheet frame)))
    (sheet-disown-child tps (frame-panes frame))
    (sheet-disown-child (graft frame) tps))
  (setf (frame-manager frame) nil))

(defmethod enable-frame ((frame menu-frame))
  (setf (sheet-enabled-p (frame-top-level-sheet frame)) t)
  (setf (slot-value frame 'state) :enabled)
  (note-frame-enabled (frame-manager frame) frame))

(defmethod disable-frame ((frame menu-frame))
  (setf (sheet-enabled-p (frame-top-level-sheet frame)) nil)
  (setf (slot-value frame 'state) :disabled)
  (note-frame-disabled (frame-manager frame) frame))

(defmethod shrink-frame ((frame menu-frame))
  (declare (ignore frame))
  (warn "MENU-FRAME can't be shrunk."))

(defun make-menu-frame (pane &key (left 0) (top 0) (min-width 1))
  (make-instance 'menu-frame :panes pane :left left :top top :min-width min-width))

;;; Frames and presentations
(defmethod frame-maintain-presentation-histories
    ((frame standard-application-frame))
  (if (find-pane-of-type (frame-panes frame) 'interactor-pane)
      t
      nil))

(defmethod frame-find-innermost-applicable-presentation
    ((frame standard-application-frame) input-context stream x y
     &key event)
  (find-innermost-applicable-presentation input-context stream
                                          x y
                                          :frame frame :event event))

(defmethod frame-input-context-button-press-handler
    ((frame standard-application-frame)
     (stream output-recording-stream)
     button-press-event)
  (let ((presentation (find-innermost-applicable-presentation
                       *input-context*
                       stream
                       (pointer-event-x button-press-event)
                       (pointer-event-y button-press-event)
                       :frame frame
                       :event button-press-event)))
    (when presentation
      (throw-highlighted-presentation presentation
                                      *input-context*
                                      button-press-event))))

(defmethod frame-input-context-button-press-handler
    ((frame standard-application-frame) stream button-press-event)
  (declare (ignore stream button-press-event))
  nil)

(defgeneric frame-update-pointer-documentation
    (frame input-context stream event))

(defconstant +button-documentation+ '((#.+pointer-left-button+ "L")
                                      (#.+pointer-middle-button+ "M")
                                      (#.+pointer-right-button+ "R")
                                      (#.+pointer-wheel-up+ "WheelUp")
                                      (#.+pointer-wheel-down+ "WheelDown")
                                      (#.+pointer-wheel-left+ "WheelLeft")
                                      (#.+pointer-wheel-right+ "WheelRight")))

(defconstant +modifier-documentation+
  '((#.+shift-key+ "sh" "Shift")
    (#.+control-key+ "c" "Control")
    (#.+meta-key+ "m" "Meta")
    (#.+super-key+ "s" "Super")
    (#.+hyper-key+ "h" "Hyper")))

;;; Give a coherent order to sets of modifier combinations.  Multi-key combos
;;; come after single keys.

(defun cmp-modifiers (a b)
  (let ((cnt-a (logcount a))
        (cnt-b (logcount b)))
    (cond ((eql cnt-a cnt-b)
           (< a b))
          (t (< cnt-a cnt-b)))))

(defun print-modifiers (stream modifiers style)
  (if (zerop modifiers)
      (when (eq style :long)
        (write-string "<nothing>" stream))
      (loop with trailing = nil
            for (bit short long) in +modifier-documentation+
            when (logtest bit modifiers)
            do (progn
                 (format stream "~:[~;-~]~A" trailing (if (eq style :short)
                                                          short
                                                          long))
                 (setq trailing t)))))

;;; XXX Warning: Changing rapidly!
;;;
;;; We don't actually want to print out the translator documentation and redraw
;;; the pointer documentation window on every motion event.  So, we compute a
;;; state object (basically modifier state and a list of the applicable
;;; presentation, translator and input context on each mouse button),
;;; compare it to the previous state object, and only write out documentation
;;; if they are different.  I suppose it's possible that this state object
;;; doesn't capture all possible documentation changes -- the doc generator is
;;; a function, after all -- but that's just tough.
;;;
;;; It would be nice to evolve this into a protocol so that elements other than
;;; presentations -- menu choices, for example -- could influence pointer
;;; documentation window.

(defgeneric frame-compute-pointer-documentation-state
    (frame input-context stream event)
  (:documentation
   "Compute a state object that will be used to generate pointer documentation."))

(defmethod frame-compute-pointer-documentation-state
    ((frame standard-application-frame) input-context stream event)
  (let* ((current-modifier (event-modifier-state event))
         (x (device-event-x event))
         (y (device-event-y event))
         (new-translators
          (loop for (button) in +button-documentation+
              for context-list = (multiple-value-list
                                  (find-innermost-presentation-context
                                   input-context
                                   stream
                                   x y
                                   :modifier-state current-modifier
                                   :button button))
              when (car context-list)
              collect (cons button context-list))))
    (list current-modifier new-translators)))

(defgeneric frame-compare-pointer-documentation-state
    (frame input-context stream old-state new-state))

(defmethod frame-compare-pointer-documentation-state
    ((frame standard-application-frame) input-context stream
     old-state new-state)
  (declare (ignore input-context stream))
  (equal old-state new-state))

(defun record-on-display (stream record)
  "Return true if `record' is part of the output history of
`stream', false otherwise."
  (labels ((worker (record)
             (or (eq record (stream-output-history stream))
                 (and (not (null (output-record-parent record)))
                      (worker (output-record-parent record))))))
    (worker record)))

(defgeneric frame-print-pointer-documentation
    (frame input-context stream state event))

(defvar *background-message-minimum-lifetime* 1
  "The amount of seconds a background message will be kept
alive.")

(defmethod frame-print-pointer-documentation
    ((frame standard-application-frame) input-context stream state event)
  (unless state
    (return-from frame-print-pointer-documentation nil))
  (destructuring-bind (current-modifier new-translators)
      state
    (let ((x (device-event-x event))
          (y (device-event-y event))
          (pstream *pointer-documentation-output*))
      (if (null new-translators)
          (when (and (background-message pstream)
                     (not (record-on-display pstream (background-message pstream))))
            (cond ((> (get-universal-time)
                      (+ (background-message-time pstream)
                         *background-message-minimum-lifetime*))
                   (setf (background-message pstream) nil))
                  (t
                   (setf (output-record-parent (background-message pstream)) nil)
                   (stream-add-output-record pstream (background-message pstream))
                   (replay (background-message pstream) pstream))))
          (loop for (button presentation translator context)
                in new-translators
                for name = (cadr (assoc button +button-documentation+))
                for first-one = t then nil
                do (progn
                     (unless first-one
                       (write-string "; " pstream))
                     (unless (zerop current-modifier)
                       (print-modifiers pstream current-modifier :short)
                       (write-string "-" pstream))
                     (format pstream "~A: " name)
                     (document-presentation-translator translator
                                                       presentation
                                                       (input-context-type context)
                                                       *application-frame*
                                                       event
                                                       stream
                                                       x y
                                                       :stream pstream
                                                       :documentation-type
                                                       :pointer))
                finally (when new-translators
                          (write-char #\. pstream))))
      ;; Wasteful to do this after doing
      ;; find-innermost-presentation-context above... look at doing this
      ;; first and then doing the innermost test.
      (let ((all-translators (find-applicable-translators
                              (stream-output-history stream)
                              input-context
                              *application-frame*
                              stream
                              x y
                              :for-menu t))
            (other-modifiers nil))
        (loop for (translator) in all-translators
              for gesture = (gesture translator)
              unless (eq gesture t)
              do (loop for (name type modifier) in gesture
                       unless (eql modifier current-modifier)
                       do (pushnew modifier other-modifiers)))
        (when other-modifiers
          (setf other-modifiers (sort other-modifiers #'cmp-modifiers))
          (terpri pstream)
          (write-string "To see other commands, press "	pstream)
          (loop for modifier-tail on other-modifiers
                for (modifier) = modifier-tail
                for count from 0
                do (progn
                     (if (null (cdr modifier-tail))
                         (progn
                           (when (> count 1)
                             (write-char #\, pstream))
                           (when (> count 0)
                             (write-string " or " pstream)))
                         (when (> count 0)
                           (write-string ", " pstream)))
                     (print-modifiers pstream modifier :long)))
          (write-char #\. pstream))))))

(defmethod frame-update-pointer-documentation
    ((frame standard-application-frame) input-context stream event)
  (when *pointer-documentation-output*
    (with-accessors ((frame-documentation-state frame-documentation-state)
                     (documentation-record documentation-record))
        frame
      (setf frame-documentation-state
            (frame-compute-pointer-documentation-state frame
                                                       input-context
                                                       stream
                                                       event))
      ;; These ugly special bindings work around the fact that the outer
      ;; updating-output form closes over its body and allow the inner
      ;; form to see the correct, current values of those variables.
      (let ((%input-context% input-context)
            (%stream% stream)
            (%doc-state% frame-documentation-state)
            (%event% event))
        (declare (special %input-context% %stream% %doc-state% %event%))
        (if (and documentation-record
                 (output-record-parent documentation-record))
            (redisplay documentation-record *pointer-documentation-output*)
            (progn
              (setf documentation-record
                    (updating-output (*pointer-documentation-output*)
                      (updating-output (*pointer-documentation-output*
                                        :cache-value %doc-state%
                                        :cache-test #'equal)
                        (frame-print-pointer-documentation frame
                                                           %input-context%
                                                           %stream%
                                                           %doc-state%
                                                           %event%))))))))))

(defgeneric invoke-with-output-to-pointer-documentation (frame continuation)
  (:documentation "Invoke `continuation' with a single argument -
a stream that the continuation can write to, the output of which
will be used as the background message of the pointer
documentation pane of `frame'. If the pointer-documentation of
`frame' is not a `pointer-documentation-pane', `continuation'
will not be called."))

(defmethod invoke-with-output-to-pointer-documentation
    ((frame standard-application-frame) continuation)
  (with-accessors ((pointer-documentation frame-pointer-documentation-output)) frame
    (when (typep pointer-documentation 'pointer-documentation-pane)
      (setf (background-message pointer-documentation)
            (with-output-to-output-record (pointer-documentation)
              (funcall continuation pointer-documentation))
            (background-message-time pointer-documentation) (get-universal-time)))))

(defmacro with-output-to-pointer-documentation ((stream frame) &body body)
  "Bind `stream' to the pointer-documentation pane of `frame' and
capture the output of `body' on `stream' as the background
message of the pointer documentation pane. If `frame' does not
have a `pointer-documentation-pane' as pointer documentation,
`body' will not be evaluated."
  `(invoke-with-output-to-pointer-documentation
    ,frame #'(lambda (,stream)
               ,@body)))

;;; A hook for applications to draw random strings in the
;;; *pointer-documentation-output* without screwing up the real pointer
;;; documentation too badly.

(defun frame-display-pointer-documentation-string (frame string)
  (with-output-to-pointer-documentation (stream frame)
      (write-string string stream))
  (let ((*pointer-documentation-output* (frame-pointer-documentation-output frame)))
    ;; To see the string it is necessary to trigger the redisplay of
    ;; pointer-documentation-pane with FRAME-UPDATE-POINTER-DOCUMENTATION.
    ;; As INPUT-CONTEXT we pass NIL. FRAME-COMPUTE-POINTER-DOCUMENTATION-STATE and
    ;; FRAME-PRINT-POINTER-DOCUMENTATION specialize on that.
    ;; We pass the STRING as EVENT argument in this way
    ;; FRAME-COMPUTE-POINTER-DOCUMENTATION-STATE calculate a new state
    ;; value cached for icremental-redisplay machinery.  -- admich 2019-11-15
    (frame-update-pointer-documentation frame nil nil string)))

(defmethod frame-compute-pointer-documentation-state
    ((frame standard-application-frame) (input-context null) stream event)
  (list :string event))

(defmethod frame-print-pointer-documentation
    ((frame standard-application-frame) (input-context null) stream state event)
  (unless state
    (return-from frame-print-pointer-documentation nil))
  (let ((pstream *pointer-documentation-output*))
    (when-let ((message (background-message pstream)))
      (cond ((record-on-display pstream message))
            ((> (get-universal-time)
                (+ (background-message-time pstream)
                   *background-message-minimum-lifetime*))
             (setf (background-message pstream) nil))
            (t
             (setf (output-record-parent message) nil)
             (stream-add-output-record pstream message)
             (replay message pstream))))))

(defmethod frame-input-context-track-pointer
    ((frame standard-application-frame)
     input-context
     (stream output-recording-stream) event)
  (declare (ignore input-context event))
  nil)

(defmethod frame-input-context-track-pointer
    ((frame standard-application-frame) input-context stream event)
  (declare (ignore input-context stream event))
  nil)

(defun frame-highlight-at-position (frame stream x y modifier input-context
                                    &key (highlight t))
  "Given stream x,y; key modifiers; input-context, find the applicable
   presentation and maybe highlight it."
  (flet ((maybe-unhighlight (presentation)
           (when (and (frame-highlited-presentation frame)
                      (or (not highlight)
                          (not (eq presentation
                                   (car (frame-highlited-presentation frame))))))
             (highlight-presentation-1 (car (frame-highlited-presentation frame))
                                       (cdr (frame-highlited-presentation frame))
                                       :unhighlight)
             (setf (frame-highlited-presentation frame) nil))))
    (if (output-recording-stream-p stream)
        (let ((presentation (find-innermost-applicable-presentation
                             input-context
                             stream
                             x y
                             :frame frame
                             :modifier-state modifier)))
          (maybe-unhighlight presentation)
          (when (and presentation
                     highlight
                     (not (eq presentation
                              (car (frame-highlited-presentation frame)))))
            (setf (frame-highlited-presentation frame)
                  (cons presentation stream))
            (highlight-presentation-1 presentation stream :highlight))
          presentation)
        (progn
          (maybe-unhighlight nil)
          nil))))

(defmethod frame-input-context-track-pointer :before
    ((frame standard-application-frame) input-context
     (stream output-recording-stream) event)
  (frame-highlight-at-position frame stream
                               (device-event-x event)
                               (device-event-y event)
                               (event-modifier-state event)
                               input-context)
  (frame-update-pointer-documentation frame input-context stream event))

(defun simple-event-loop (&optional (frame *application-frame*))
  "An simple event loop for applications that want all events to be handled by
 handle-event methods"
  (let ((queue (frame-event-queue frame)))
    (loop for event = (event-queue-read queue)
       ;; EVENT-QUEUE-READ in single-process mode calls PROCESS-NEXT-EVENT itself.
       do (handle-event (event-sheet event) event))))

;;; Am I missing something?  Does this need to do more? - moore
(defmacro with-application-frame ((frame) &body body)
  `(let ((,frame *application-frame*))
     ,@body))

(defmethod (setf client-setting) (value frame setting)
  (setf (getf (client-settings frame) setting) value))

(defmethod reset-frame (frame &rest client-settings)
  (loop for (setting value) on client-settings by #'cddr
        do (setf (client-setting frame setting) value)))


(defmethod frame-drag-and-drop-feedback
    ((frame standard-application-frame) from-presentation stream
     initial-x initial-y x y state))

(defmethod frame-drag-and-drop-feedback
    ((frame standard-application-frame) from-presentation (stream encapsulating-stream)
     initial-x initial-y x y state)
  (frame-drag-and-drop-feedback frame from-presentation (encapsulating-stream-stream stream)
                                initial-x initial-y x y state))

(defmethod frame-drag-and-drop-feedback
    ((frame standard-application-frame) from-presentation (stream output-recording-stream)
     initial-x initial-y x y state)
  (with-bounding-rectangle* (fp-x1 fp-y1 fp-x2 fp-y2)
      from-presentation
    ;; Offset from origin of presentation is preserved throughout
    (let* ((x-off (-  fp-x1 initial-x))
           (y-off (-  fp-y1 initial-y))
           (highlite-x1 (+ x-off x))
           (highlite-y1 (+ y-off y))
           (highlite-x2 (+ highlite-x1 (- fp-x2 fp-x1)))
           (highlite-y2 (+ highlite-y1 (- fp-y2 fp-y1))))
      (with-identity-transformation (stream)
        (ecase state
          (:highlight
           (with-output-recording-options (stream :record nil)
             (draw-rectangle* stream highlite-x1 highlite-y1 highlite-x2 highlite-y2
                              :filled nil :line-dashes #(4 4))))
          (:unhighlight
           (with-output-recording-options (stream :record nil)
             (draw-rectangle* stream
                              highlite-x1 highlite-y1
                              (1+ highlite-x2) (1+ highlite-y2)
                              :ink (medium-background (sheet-medium stream))))
           (stream-replay stream (make-rectangle* highlite-x1 highlite-y1
                                                  (1+ highlite-x2) (1+ highlite-y2)))))))))

(defmethod frame-drag-and-drop-highlighting
    ((frame standard-application-frame) to-presentation stream state)
  (highlight-presentation-1 to-presentation stream state))
