(defun hex-dump-to-lisp (start end)
  (interactive "r")
  (beginning-of-line)
  (while (looking-at "^[ \t]*[0-9A-Fa-f]\\{4\\}[ \t]*\\(.*?\\)   .*$")
    (replace-match
     (replace-regexp-in-string
      "\\([0-9A-Fa-f]\\{2\\}\\)"
      "#x\\1"
      (match-string 1)))
    (forward-line)
    (beginning-of-line)))
