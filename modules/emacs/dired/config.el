;;; tools/dired/config.el -*- lexical-binding: t; -*-

(use-package! dired
  :commands dired-jump
  :init
  (setq dired-dwim-target t  ; suggest a target for moving/copying intelligently
        dired-hide-details-hide-symlink-targets nil
        ;; don't prompt to revert, just do it
        dired-auto-revert-buffer #'dired-buffer-stale-p
        ;; Always copy/delete recursively
        dired-recursive-copies  'always
        dired-recursive-deletes 'top
        ;; Where to store image caches
        image-dired-dir (concat doom-cache-dir "image-dired/")
        image-dired-db-file (concat image-dired-dir "db.el")
        image-dired-gallery-dir (concat image-dired-dir "gallery/")
        image-dired-temp-image-file (concat image-dired-dir "temp-image")
        image-dired-temp-rotate-image-file (concat image-dired-dir "temp-rotate-image")
        ;; Screens are larger nowadays, we can afford slightly larger thumbnails
        image-dired-thumb-size 150)
  :config
  (set-popup-rule! "^\\*image-dired"
    :slot 20 :size 0.8 :select t :quit nil :ttl 0)
  (set-evil-initial-state! 'image-dired-display-image-mode 'emacs)

  (let ((args (list "-ahl" "-v" "--group-directories-first")))
    (when IS-BSD
      ;; Use GNU ls as `gls' from `coreutils' if available.
      (if-let (gls (executable-find "gls"))
          (setq insert-directory-program gls)
        ;; BSD ls doesn't support -v or --group-directories-first
        (setq args (list (car args))
              ;; or --dired
              dired-use-ls-dired nil)))
    (setq dired-listing-switches (string-join args " "))

    (add-hook! 'dired-mode-hook
      (defun +dired-disable-gnu-ls-flags-maybe-h ()
        "Remove extraneous switches from `dired-actual-switches' when it's
uncertain that they are supported (e.g. over TRAMP or on Windows).

Fixes #1703: dired over TRAMP displays a blank screen.
Fixes #3939: unsortable dired entries on Windows."
        (when (or (file-remote-p default-directory)
                  (and (boundp 'ls-lisp-use-insert-directory-program)
                       (not ls-lisp-use-insert-directory-program)))
          (setq-local dired-actual-switches (car args))))))

  ;; Don't complain about this command being disabled when we use it
  (put 'dired-find-alternate-file 'disabled nil)

  (defadvice! +dired--no-revert-in-virtual-buffers-a (&rest args)
    "Don't auto-revert in dired-virtual buffers (see `dired-virtual-revert')."
    :before-while #'dired-buffer-stale-p
    (not (eq revert-buffer-function #'dired-virtual-revert)))

  (map! :map dired-mode-map
        ;; Kill all dired buffers on q
        :ng "q" #'+dired/quit-all
        ;; To be consistent with ivy/helm+wgrep integration
        "C-c C-e" #'wdired-change-to-wdired-mode))


(use-package! dired-rsync
  :general (dired-mode-map "C-c C-r" #'dired-rsync))

;; Extra font locking for dired
(use-package! diredfl
  :hook (dired-mode . diredfl-mode))

;; diff-hl indicators are incorrect when you navigate to,
;; from, and back to a directory. note that ranger-refresh
;; fixes the issue temporarily but takes a while to run
;; (use-package! diff-hl
;;   :hook (dired-mode . diff-hl-dired-mode-unless-remote)
;;   :hook (magit-post-refresh . diff-hl-magit-post-refresh)
;;   :config
;;   ;; use margin instead of fringe
;;   (diff-hl-margin-mode))


;; HACK ranger is unstable. It breaks at random times, as observed in
;; https://github.com/syl20bnr/spacemacs/issues/13129. Sometimes
;; splitting a window, then trying to open a buffer spawns an
;; error from delete-window about deleting the sole window or
;; minibuffer and falls back to a single window.
(use-package! ranger
  :when (featurep! +ranger)
  :after dired
  :init
  (setq ranger-override-dired t
        ranger-excluded-extensions '("mkv" "iso" "mp4")
        ranger-preview-file nil
        ;; The ranger header is ugly and has odd indentation
        ranger-modify-header nil
        ;; The docs for this variable are wrong.
        ranger-show-hidden 'format
        ;; Commands that prompt for a directory (dired commands,
        ;; org-attach-attach, etc.) will prompt for the directory in the
        ;; (possibly second) dired buffer. E.g. this is useful for
        ;; dired-do-copy.
        dired-dwim-target #'dired-dwim-target-ranger)
  :config
  ;; Modified to open WSL files in Windows
  ;; NOTE Bound to "we" in ranger-mode-map
  (advice-add 'ranger-open-in-external-app
              :override 'my/ranger-open-in-external-app)

  ;; BUG There was a typo in the original function
  (advice-add 'ranger-disable :override 'my/ranger-disable)

  (add-hook 'window-configuration-change-hook #'temp-ranger-hack)

  (unless (file-directory-p image-dired-dir)
    (make-directory image-dired-dir))

  (set-popup-rule! "^\\*ranger" :ignore t)

  (defadvice! +dired--cleanup-header-line-a ()
    "Ranger fails to clean up `header-line-format' when it is closed, so..."
    :before #'ranger-revert
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (equal header-line-format '(:eval (ranger-header-line)))
            (setq header-line-format nil))))))

  (defadvice! +dired--cleanup-mouse1-bind-a ()
    "Ranger binds an anonymous function to mouse-1 after previewing a buffer
that prevents the user from escaping the window with the mouse. This command is
never cleaned up if the buffer already existed before ranger was initialized, so
we have to clean it up ourselves."
    :after #'ranger-setup-preview
    (when (window-live-p ranger-preview-window)
      (with-current-buffer (window-buffer ranger-preview-window)
        (local-unset-key [mouse-1]))))

  (defadvice! +dired--ranger-travel-a ()
    "Temporary fix for this function until ralesi/ranger.el#236 gets merged."
    :override #'ranger-travel
    (interactive)
    (let ((prompt "Travel: "))
      (cond
       ((bound-and-true-p helm-mode)
        (ranger-find-file (helm-read-file-name prompt)))
       ((bound-and-true-p ivy-mode)
        (ivy-read prompt 'read-file-name-internal
                  :matcher #'counsel--find-file-matcher
                  :action
                  (lambda (x)
                    (with-ivy-window
                     (ranger-find-file (expand-file-name x default-directory))))))
       ((bound-and-true-p ido-mode)
        (ranger-find-file (ido-read-file-name prompt)))
       (t
        (ranger-find-file (read-file-name prompt)))))))


(use-package! all-the-icons-dired
  :when (featurep! +icons)
  :hook (dired-mode . all-the-icons-dired-mode)
  :config
  ;; HACK Fixes #1929: icons break file renaming in Emacs 27+, because the icon
  ;;      is considered part of the filename, so we disable icons while we're in
  ;;      wdired-mode.
  (defvar +wdired-icons-enabled -1)

  ;; display icons with colors
  (setq all-the-icons-dired-monochrome nil)

  (defadvice! +dired-disable-icons-in-wdired-mode-a (&rest _)
    :before #'wdired-change-to-wdired-mode
    (setq-local +wdired-icons-enabled (if all-the-icons-dired-mode 1 -1))
    (when all-the-icons-dired-mode
      (all-the-icons-dired-mode -1)))

  (defadvice! +dired-restore-icons-after-wdired-mode-a (&rest _)
    :after #'wdired-change-to-dired-mode
    (all-the-icons-dired-mode +wdired-icons-enabled)))


(use-package! dired-x
  :unless (featurep! +ranger)
  :hook (dired-mode . dired-omit-mode)
  :config
  (setq dired-omit-verbose nil
        dired-omit-files
        (concat dired-omit-files
                "\\|^\\.DS_Store\\'"
                "\\|^\\.project\\(?:ile\\)?\\'"
                "\\|^\\.\\(?:svn\\|git\\)\\'"
                "\\|^\\.ccls-cache\\'"
                "\\|\\(?:\\.js\\)?\\.meta\\'"
                "\\|\\.\\(?:elc\\|o\\|pyo\\|swp\\|class\\)\\'"))
  ;; Disable the prompt about whether I want to kill the Dired buffer for a
  ;; deleted directory. Of course I do!
  (setq dired-clean-confirm-killing-deleted-buffers nil)
  ;; Let OS decide how to open certain files
  (when-let (cmd (cond (IS-MAC "open")
                       (IS-LINUX "xdg-open")
                       (IS-WINDOWS "start")))
    (setq dired-guess-shell-alist-user
          `(("\\.\\(?:docx\\|pdf\\|djvu\\|eps\\)\\'" ,cmd)
            ("\\.\\(?:jpe?g\\|png\\|gif\\|xpm\\)\\'" ,cmd)
            ("\\.\\(?:xcf\\)\\'" ,cmd)
            ("\\.csv\\'" ,cmd)
            ("\\.tex\\'" ,cmd)
            ("\\.\\(?:mp4\\|mkv\\|avi\\|flv\\|rm\\|rmvb\\|ogv\\)\\(?:\\.part\\)?\\'" ,cmd)
            ("\\.\\(?:mp3\\|flac\\)\\'" ,cmd)
            ("\\.html?\\'" ,cmd)
            ("\\.md\\'" ,cmd))))
  (map! :map dired-mode-map
        :localleader
        "h" #'dired-omit-mode))


(use-package! dired-aux
  :defer t
  :config
  (setq dired-create-destination-dirs 'ask
        dired-vc-rename-file t))

