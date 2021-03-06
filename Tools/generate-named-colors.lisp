;;; I used this function to generate the predefined colors and names - mikemac@mikemac.com

(defun generate-named-colors ()
  (with-open-file (out "colors.lisp" :direction :output :if-exists :supersede)
    (with-open-file (in "/usr/share/X11/rgb.txt" :direction :input)
      (format out ";;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-~%~%")
      (format out ";;; This file is generated by ~s.~%~%"
              "Tools/generate-named-colors.lisp")
      (format out "(in-package :clim-internals)~%~%")
      (loop with names = nil
            for line = (read-line in nil nil)
            until (null line)
            do (if (eql (aref line 0) #\!)
                   (format out ";~A~%" (subseq line 1))
                   (multiple-value-bind (red index)
                       (parse-integer line :start 0 :junk-allowed t)
                     (multiple-value-bind (green index)
                         (parse-integer line :start index :junk-allowed t)
                       (multiple-value-bind (blue index)
                           (parse-integer line :start index :junk-allowed t)
                         (let ((name (substitute #\- #\Space (string-trim '(#\Space #\Tab #\Newline) (subseq line index)))))
                           (format out "(defconstant +~A+ (make-named-color ~S ~,4F ~,4F ~,4F))~%" name name (/ red 255.0) (/ green 255.0) (/ blue 255.0))
                           (setq names (nconc names (list name))))))))
            finally (format out "(eval-when (eval compile load)~%  (export '(")
                    (loop for name in names
                          for count = 1 then (1+ count)
                          do (format out "+~A+ " name)
                             (when (= count 4)
                               (format out "~%            ")
                               (setq count 0)))
                    (format out "~%           )))~%")))))
