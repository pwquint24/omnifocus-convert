;;; omnifocus-convert.el --- Convert OmniFocus XML export to Org-mode  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Parses an OmniFocus XML export (contents.xml) using built-in Emacs
;; capabilities and emits Org-mode entries with property drawers.
;;
;; Pipeline:
;;   1. `omnifocus-parse-file'   -> DOM via xml-parse-file
;;   2. `omnifocus-index'        -> hash table of id -> task plist
;;   3. `omnifocus-hierarchy'    -> "Parent Project/Sub-Project/Task"
;;   4. `omnifocus-tag-index'    -> task id -> tag paths (from <task-to-tag>)
;;   5. `omnifocus-format-entry' -> Org heading + tags + property drawer
;;
;; Entry points:
;;   `omnifocus-convert-file'    FILE   -> Org string (reads from disk)
;;   `omnifocus-convert-buffer'  BUFFER -> new buffer in `org-mode'
;;   `omnifocus-convert-region'  START END -> new buffer, region only
;;   `omnifocus-convert-root'    DOM    -> Org string (already-parsed input)
;;
;; Note: `libxml-parse-xml-region' is not available in all builds, so this
;; uses `xml.el' (`xml-parse-file'), which yields a DOM of nested lists of
;; the form (TAG ((ATTR . VALUE) ...) CHILD...).  Text nodes are bare
;; strings, and self-closing elements such as <due/> produce (due).
;;
;; Tags: there are no <tag> elements in an OmniFocus 4 export - tags are
;; <context> elements joined to tasks through <task-to-tag> rows.  Tag paths
;; such as "People/Lakshika" are flattened into legal Org tags (see
;; `omnifocus-format-tags').

;;; Code:

(require 'xml)
(require 'seq)
(require 'subr-x)
;; Only needed so the buffer-producing entry points can put the result into
;; `org-mode'; the conversion itself is pure string building.
(require 'org)

(defgroup omnifocus nil
  "Convert OmniFocus XML exports to Org-mode."
  :group 'org)

(defcustom omnifocus-inbox-label "Inbox"
  "Label used as the hierarchy root for items with no assigned project."
  :type 'string)

(defcustom omnifocus-separator "/"
  "Separator used between hierarchy path components."
  :type 'string)

(defcustom omnifocus-include-completed t
  "When non-nil, include tasks that have a completion date."
  :type 'boolean)

(defcustom omnifocus-tag-separator "/"
  "Separator used between tag path components, e.g. \"People/Lakshika\"."
  :type 'string)

(defcustom omnifocus-tag-inherit-groups nil
  "When non-nil, also emit the ancestor of each tag as its own Org tag.

For example, a task tagged \"People/Lakshika\" would additionally receive the
plain tag \"People\", letting `org-agenda' match every person with a single
tag.  This is a lossy convenience: it can produce surprising matches when a
group name such as \"People\" is also used directly as a tag."
  :type 'boolean)

;;; Parsing

(defun omnifocus-parse-file (file)
  "Parse the OmniFocus XML export at FILE and return its root DOM node."
  (let ((dom (xml-parse-file file)))
    ;; `xml-parse-file' returns (document ... ROOT); the root element is last.
    (car (last dom))))

(defun omnifocus-parse-buffer (&optional buffer)
  "Parse the OmniFocus XML export in BUFFER and return its root DOM node.

BUFFER defaults to the current buffer.  Use this to convert an export that is
open in Emacs but not saved to disk, or whose contents came from somewhere
other than a file.  Narrowing is honoured, so the region can be restricted
first if the buffer holds more than the export."
  (with-current-buffer (or buffer (current-buffer))
    (save-restriction
      (widen)
      (car (last (xml-parse-region (point-min) (point-max)))))))

;; Nodes produced by `xml.el' are raw lists shaped (TAG ATTRS CHILD...), where
;; ATTRS is a flat alist such as ((id . "abc")) or ((idref . "xyz")).  The
;; `dom.el' accessors cannot be used directly: `dom-by-tag' flattens the tree
;; (losing whether an element was self-closing), and `dom-attr' misreads the
;; attribute compound.  So walk the raw list structure instead.

(defun omnifocus--tag-p (node tag)
  "Return non-nil when NODE is an element whose tag symbol is TAG."
  (and (consp node) (eq (car node) tag)))

(defun omnifocus--children (node)
  "Return NODE's child elements (self-closing elements included)."
  (seq-filter #'consp (cddr node)))

(defun omnifocus--child (node tag)
  "Return the first child element of NODE whose tag is TAG, or nil.

A self-closing <tag/> is returned as (TAG nil), so its presence can be
distinguished from absence.  `dom-by-tag' cannot be used here because it
flattens the tree and so cannot tell <project/> from a populated <project>."
  (seq-find (lambda (child) (omnifocus--tag-p child tag))
            (omnifocus--children node)))

(defun omnifocus--child-text (node tag)
  "Return the text content of NODE's first TAG child, or nil when absent/empty.

Returns nil (rather than \"\") for self-closing elements like <due/> so that
callers can omit the corresponding property.  Text is the concatenation of
the string children; `dom-text' is avoided because it is obsolete as of
Emacs 31.1 and because these are raw `xml.el' nodes."
  (let* ((child (omnifocus--child node tag))
         (text (and child
                    (string-trim
                     (mapconcat (lambda (c) (if (stringp c) c ""))
                                (cddr child) ""))))
         )
    (and (stringp text) (not (string-empty-p text)) text)))

(defun omnifocus--attr (node name)
  "Return the value of attribute NAME (a symbol) on element NODE, or nil.

Attributes arrive as a flat alist, e.g. ((id . \"fN3bX3_YGkG\")), so a plain
`assq' lookup is correct here."
  (let ((attrs (cadr node)))
    (cdr (assq name attrs))))

(defun omnifocus--child-attr (node tag attr)
  "Return attribute ATTR of NODE's first TAG child, or nil."
  (let ((child (omnifocus--child node tag)))
    (and child (omnifocus--attr child attr))))

(defun omnifocus--oneline (text)
  "Collapse whitespace in TEXT so it fits on a single Org heading line.

Three tasks in the real export have multi-line <name> elements: the title
field was used as a free-text area, so it holds several sentences separated
by newlines.  An Org headline cannot span lines - a stray newline would make
the remainder look like a new heading and detach the property drawer - so
runs of whitespace are folded into single spaces."
  (when (and text (not (string-empty-p (string-trim text))))
    (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " text))))

;;; Indexing

(defun omnifocus--collect-tasks (node acc)
  "Accumulate every <task> element under NODE into ACC, returning ACC.

Walks the raw `xml.el' tree directly.  `dom-by-tag' is not used because it
flattens the tree and so loses the distinction between a self-closing
element and a populated one."
  (when (consp node)
    (when (omnifocus--tag-p node 'task)
      (push node acc))
    (dolist (child (omnifocus--children node))
      (setq acc (omnifocus--collect-tasks child acc))))
  acc)

(defun omnifocus-task-nodes (root)
  "Return the list of real <task> nodes under ROOT.

<attachment> and <context> elements also contain <task idref=\"...\"/> children,
so the walk collects every <task> and the caller filters by ID: a genuine task
record always carries one."
  (seq-filter (lambda (node) (omnifocus--attr node 'id))
              (omnifocus--collect-tasks root nil)))

(defun omnifocus-task-record (node)
  "Build a plist describing the <task> DOM NODE.

`:is-project' is t when the <project> child is a non-empty element (i.e. it
carries <status>, <last-review>, etc.) rather than self-closing <project/>."
  (let* ((id (omnifocus--attr node 'id))
         (project-node (omnifocus--child node 'project))
         (is-project (and project-node (omnifocus--children project-node) t))
         (inbox-text (omnifocus--child-text node 'inbox))
         (flagged-text (omnifocus--child-text node 'flagged)))
    (list :id id
          :name (or (omnifocus--oneline (omnifocus--child-text node 'name))
                    "(unnamed)")
          :parent-id (omnifocus--child-attr node 'task 'idref)
          :is-project is-project
          :is-inbox (equal inbox-text "true")
          :note (omnifocus--child-text node 'note)
          :added (omnifocus--child-text node 'added)
          :modified (omnifocus--child-text node 'modified)
          :start (omnifocus--child-text node 'start)
          :due (omnifocus--child-text node 'due)
          :completed (omnifocus--child-text node 'completed)
          :flagged (equal flagged-text "true")
          :estimated-minutes (omnifocus--child-text node 'estimated-minutes)
          :repetition-rule (omnifocus--child-text node 'repetition-rule)
          :rank (omnifocus--child-text node 'rank))))

(defun omnifocus-index (root)
  "Return a hash table mapping task ID to task plist for all tasks under ROOT."
  (let ((table (make-hash-table :test 'equal :size 4096)))
    (dolist (node (omnifocus-task-nodes root) table)
      (let ((record (omnifocus-task-record node)))
        (puthash (plist-get record :id) record table)))))

(defun omnifocus-task (index id)
  "Return the task plist for ID from INDEX, or nil when unknown."
  (and id (gethash id index)))

;;; Hierarchy resolution

(defcustom omnifocus-max-depth 32
  "Maximum ancestry depth to walk before assuming a cyclic parent chain.
Real OmniFocus exports are only two levels deep; this is purely a safety
valve against a malformed document."
  :type 'integer)

(defun omnifocus-ancestry (index id)
  "Return the list of task IDs from the root down to ID (inclusive).

Follows `:parent-id' links to the top.  Returns nil if ID is not in INDEX.
Signals an error on a referential cycle rather than looping forever.

A `:parent-id' that is not present in INDEX ends the walk: this happens in
partial extracts, where an action's project was not included in the file."
  (let ((chain nil)
        (seen (make-hash-table :test 'equal))
        (current id)
        (depth 0))
    (unless (gethash id index)
      (error "Task %s not found in index" id))
    (while (and current (< depth omnifocus-max-depth))
      (when (gethash current seen)
        (error "Cyclic parent chain detected at task %s" current))
      (puthash current t seen)
      (push current chain)
      (setq depth (1+ depth))
      ;; An unknown parent just ends the walk (partial extract); only the
      ;; starting task itself is required to exist.
      (let ((parent (plist-get (gethash current index) :parent-id)))
        (setq current (and parent (gethash parent index) parent))))
    (when (>= depth omnifocus-max-depth)
      (error "Ancestry of %s exceeds %d levels (possible cycle)"
             id omnifocus-max-depth))
    chain))

(defun omnifocus-hierarchy (index id)
  "Return the hierarchy path string for the task ID in INDEX.

The path is the breadcrumb of ancestor names joined by the separator, with
the task's own name last.  Inbox items are rooted at `omnifocus-inbox-label',
because they have no parent task by construction.  When the parent is not in
INDEX (a partial extract) the path simply starts at the task itself."
  (let* ((record (gethash id index))
         (chain (omnifocus-ancestry index id))
         ;; `chain' is root-first and includes ID itself as its last element,
         ;; so its names already read as the final breadcrumb.
         (names (mapcar (lambda (tid) (plist-get (gethash tid index) :name))
                        chain)))
    (if (plist-get record :is-inbox)
        ;; Inbox items are roots in the document but belong under "Inbox".
        (mapconcat #'identity (cons omnifocus-inbox-label names)
                   omnifocus-separator)
      (when names
        (mapconcat #'identity names omnifocus-separator)))))

(defun omnifocus-hierarchy-safe (index id)
  "Like `omnifocus-hierarchy' for task ID in INDEX, but never signals.

Returns a diagnostic string instead, so that one malformed record cannot
abort a wholesale export."
  (condition-case err
      (omnifocus-hierarchy index id)
    (error (format "(unresolved: %s)" (error-message-string err)))))

;;; Tag indexing
;;
;; In the OmniFocus 4 export there are no <tag> elements: the old "context"
;; concept was merged into tags, so a tag IS a <context> element and tag
;; assignment is a many-to-many <task-to-tag> join table.
;;
;; This matters for correctness.  Every <task> also carries a <context> child,
;; but for an untagged task that child is self-closing and empty, and for a
;; multi-tagged task it holds only the *first* tag.  Deriving tags from the
;; <context> child therefore (a) matches every task rather than only the tagged
;; ones, and (b) silently drops the extra tags on multi-tagged tasks.  The
;; <task-to-tag> rows are the authoritative source.

(defun omnifocus--collect-elements (node tag acc)
  "Accumulate every element named TAG under NODE into ACC, returning ACC.

Unlike `omnifocus--collect-tasks' this does not filter on an `id' attribute,
because contexts are keyed differently from tasks."
  (when (consp node)
    (when (omnifocus--tag-p node tag)
      (push node acc))
    (dolist (child (omnifocus--children node))
      (setq acc (omnifocus--collect-elements child tag acc))))
  acc)

(defun omnifocus-tag-index (root)
  "Return a cons of the two tag lookup tables built from ROOT.

The car is a hash table mapping a task ID to the list of context IDs assigned
to it (in document order), built from the <task-to-tag> join rows.

The cdr is a hash table mapping a context ID to a cons cell (NAME . PARENT-ID),
where NAME may be nil for a context whose <name> is empty, and PARENT-ID is nil
for a root tag.

<task-to-tag> is used rather than each task's <context> child because that
child is an incomplete, denormalised cache of only the first tag."
  (let ((task-tags (make-hash-table :test 'equal :size 1024))
        (contexts (make-hash-table :test 'equal :size 64)))
    (dolist (ctx (omnifocus--collect-elements root 'context nil))
      (let ((cid (omnifocus--attr ctx 'id)))
        (when cid
          (puthash cid
                   (cons (omnifocus--oneline (omnifocus--child-text ctx 'name))
                         (omnifocus--child-attr ctx 'context 'idref))
                   contexts))))
    (dolist (join (omnifocus--collect-elements root 'task-to-tag nil))
      (let ((task-id (omnifocus--child-attr join 'task 'idref))
            (context-id (omnifocus--child-attr join 'context 'idref)))
        (when (and task-id context-id)
          (puthash task-id
                   (append (gethash task-id task-tags) (list context-id))
                   task-tags))))
    (cons task-tags contexts)))

(defun omnifocus-tags (tag-index task-id)
  "Return the raw list of context IDs assigned to TASK-ID in TAG-INDEX.

TAG-INDEX is a cons as returned by `omnifocus-tag-index'."
  (gethash task-id (car tag-index)))

(defcustom omnifocus-max-tag-depth 16
  "Maximum tag ancestry depth to walk before assuming a cyclic chain."
  :type 'integer)

(defun omnifocus-tag-path (tag-index context-id)
  "Return the full tag path string for CONTEXT-ID in TAG-INDEX.

Contexts nest via their own <context idref=\"...\"/> child, so a tag renders
as \"People/Lakshika\".  A parent missing from the table ends the walk (a
partial extract); a referential cycle signals an error rather than looping."
  (let ((contexts (cdr tag-index))
        (parts nil)
        (seen (make-hash-table :test 'equal))
        (current context-id)
        (depth 0))
    (while (and current (< depth omnifocus-max-tag-depth))
      (when (gethash current seen)
        (error "Cyclic tag chain detected at context %s" current))
      (puthash current t seen)
      (let ((entry (gethash current contexts)))
        ;; An unknown context (partial extract) still contributes its own ID so
        ;; that a tag is never silently dropped.
        (let ((name (or (car entry) current)))
          (push name parts))
        (setq current (and entry (cdr entry))))
      (setq depth (1+ depth)))
    (when (>= depth omnifocus-max-tag-depth)
      (error "Tag ancestry of %s exceeds %d levels (possible cycle)"
             context-id omnifocus-max-tag-depth))
    (mapconcat #'identity (delete "" parts) omnifocus-separator)))

(defun omnifocus-tag-path-safe (tag-index context-id)
  "Like `omnifocus-tag-path' for CONTEXT-ID in TAG-INDEX, but never signals."
  (condition-case err
      (omnifocus-tag-path tag-index context-id)
    (error (format "(unresolved-tag: %s)" (error-message-string err)))))

(defun omnifocus--escape-tag (path)
  "Convert a tag PATH such as \"People/Lakshika\" into a legal Org tag.

Org accepts only the characters [[:alnum:]_@#%] in a tag, and splits on
whitespace, so `/` and spaces are mapped to `_' (the conventional Org
separator replacement).  Runs of separators collapse to a single underscore
and any remaining illegal character is dropped, so that a tag path can never
break the `:tag1:tag2:' syntax of a heading line."
  (when (and path (not (string-empty-p path)))
    (let* ((replaced (replace-regexp-in-string
                      "[][/[:space:]]+" "_" path))
           (cleaned (replace-regexp-in-string
                     "[^[:alnum:]_@#%]" "" replaced))
           (trimmed (replace-regexp-in-string
                     "\\`_+\\|_+\\'" "" cleaned)))
      (and (not (string-empty-p trimmed)) trimmed))))

(defun omnifocus-format-tags (tag-index task-id)
  "Return the Org tag string for TASK-ID in TAG-INDEX, or \"\".

The result is a leading-space, space-separated list of `:tag:' tokens ready
to append to a heading, e.g. \" :People_Lakshika:Meetings_Political:\".  Tags
are deduplicated and sorted so that output is deterministic.  Returns the
empty string when the task has no tags, so callers can concatenate blindly."
  (let* ((paths (mapcar (lambda (cid)
                          (omnifocus-tag-path-safe tag-index cid))
                        (omnifocus-tags tag-index task-id)))
         (escaped (seq-keep #'omnifocus--escape-tag paths))
         (with-groups (if omnifocus-tag-inherit-groups
                          (append escaped
                                  (seq-keep (lambda (tag)
                                              (when (string-match "\\`\\(.*\\)_.*\\'" tag)
                                                (match-string 1 tag)))
                                            escaped))
                        escaped))
         (unique (sort (delete-dups (copy-sequence with-groups)) #'string<)))
    (if unique
        (concat " :" (mapconcat #'identity unique ":") ":")
      "")))

;;; Org output

(defcustom omnifocus-org-timestamp-format "%Y-%m-%d %a %H:%M"
  "`format-time-string' pattern used for OmniFocus date metadata in drawers."
  :type 'string)

(defun omnifocus--format-timestamp (stamp)
  "Convert ISO-8601 STAMP to an Org-friendly string, or nil if unusable.

OmniFocus uses two conventions in the same file, verified against the export:

  - `added', `modified' and `completed' are true UTC instants and always end
    in `Z' (e.g. 2025-05-04T11:38:02.255Z).  These are converted into the
    local time zone, which is what a human wants to read.
  - `start' and `due' are *local wall-clock* values and never carry a zone
    (e.g. 2026-04-22T00:00:00.000 meaning midnight local).  These must be
    rendered verbatim; treating them as UTC would shift them by the local
    offset and turn midnight into 05:30.

Falls back to returning STAMP verbatim when it cannot be parsed, so no data
is silently dropped."
  (when (and stamp (not (string-empty-p stamp)))
    (let ((utc (string-suffix-p "Z" stamp)))
      (if utc
          (let ((parsed (condition-case nil
                            (date-to-time (replace-regexp-in-string
                                           "\\.[0-9]+Z\\'" "Z" stamp))
                          (error nil))))
            (if parsed
                (format-time-string omnifocus-org-timestamp-format parsed)
              stamp))
        ;; Local wall-clock: strip the fractional seconds and format as-is.
        (let ((clean (replace-regexp-in-string "\\.[0-9]+\\'" "" stamp)))
          (condition-case nil
              (format-time-string omnifocus-org-timestamp-format
                                  (date-to-time clean))
            (error stamp)))))))

(defun omnifocus--planning-string (stamp)
  "Convert ISO-8601 STAMP into an Org active timestamp `<...>', or nil.

OmniFocus's defer date, the start element, maps to Org's SCHEDULED, and its due
date, the due element, maps to Org's DEADLINE, so these are emitted as real Org
planning info
on the heading line rather than as inert property-drawer entries.  Using an
active (angle-bracket) timestamp means they show up in the agenda and feed
`org-scheduled-string'/`org-deadline-string' comparisons.

Only the date and time are kept; the trailing day name is left to Org itself."
  (when (and stamp (not (string-empty-p stamp)))
    (let ((formatted (omnifocus--format-timestamp stamp)))
      (when (and formatted (not (string-empty-p formatted)))
        (concat "<" formatted ">")))))

(defun omnifocus--planning-line (index id)
  "Return the Org planning line for task ID in INDEX, or nil.

Emits \"SCHEDULED: <...>\" and \"DEADLINE: <...>\" on one line, as Org requires
when a heading carries both.  Returns nil when the task has neither, so that no
stray planning line is emitted for undated work."
  (let* ((record (gethash id index))
         (scheduled (omnifocus--planning-string (plist-get record :start)))
         (deadline (omnifocus--planning-string (plist-get record :due)))
         (parts (delq nil (list (when scheduled (concat "SCHEDULED: " scheduled))
                                (when deadline (concat "DEADLINE: " deadline))))))
    (when parts
      (concat (mapconcat #'identity parts " ") "\n"))))

(defun omnifocus-property-alist (index id)
  "Return an ordered alist of Org property names to values for task ID in INDEX.

Properties with no value are omitted entirely rather than emitted empty, so
self-closing elements like <estimated-minutes/> leave no trace in the drawer.

There is no HIERARCHY property: the task's place is expressed by the real Org
tree the converter emits (projects as top-level headings, tasks and inbox items
nested beneath them).

There are no START or DUE properties either: `<start>' and `<due>' are emitted
as SCHEDULED and DEADLINE planning info on the heading line (see
`omnifocus--planning-line'), which is the only form Org actually understands."
  (let* ((record (gethash id index))
         (props (list (cons "OMNIFOCUS_ID" id)
                      (cons "ADDED" (omnifocus--format-timestamp
                                     (plist-get record :added)))
                      (cons "MODIFIED" (omnifocus--format-timestamp
                                        (plist-get record :modified)))
                      (cons "COMPLETED" (omnifocus--format-timestamp
                                         (plist-get record :completed)))
                      (cons "FLAGGED" (if (plist-get record :flagged)
                                          "true" "false"))
                      (cons "ESTIMATED_MINUTES"
                            (plist-get record :estimated-minutes))
                      (cons "REPETITION_RULE"
                            (plist-get record :repetition-rule)))))
    (seq-filter (lambda (pair)
                  (let ((v (cdr pair)))
                    (and v (not (equal v "")))))
                props)))

(defun omnifocus-format-entry (index id &optional tag-index level)
  "Return the Org heading and property drawer for task ID in INDEX as a string.

LEVEL is the Org outline depth (an integer, default 1) used to emit the right
number of leading stars.  The heading is the task name, followed by any Org
tags from TAG-INDEX (a cons as returned by `omnifocus-tag-index') and the
`:inbox:' tag for inbox items.  A SCHEDULED/DEADLINE planning line follows the
heading when the task has a defer or due date, and then the drawer holds the
metadata from `omnifocus-property-alist'.  Returns nil if ID is unknown."
  (let ((record (gethash id index)))
    (when record
      (let* ((name (plist-get record :name))
             (todo (cond ((plist-get record :completed) "DONE")
                         ((plist-get record :is-project) nil)
                         (t "TODO")))
             (tags (concat (if tag-index
                               (omnifocus-format-tags tag-index id)
                             "")
                           (if (plist-get record :is-inbox) " :inbox:" "")))
             (props (omnifocus-property-alist index id))
             (planning (omnifocus--planning-line index id)))
        (concat
         (format "%s %s%s%s\n"
                 (make-string (or level 1) ?*)
                 (if todo (concat todo " ") "")
                 name
                 tags)
         ;; Org requires the planning line to sit between the heading and the
         ;; property drawer; putting it in the drawer would make it inert.
         (if planning planning "")
         ":PROPERTIES:\n"
         (mapconcat (lambda (pair)
                      (format ":%s: %s" (car pair) (cdr pair)))
                    props "\n")
         "\n:END:\n")))))

(defun omnifocus-ids (index)
  "Return all task IDs in INDEX in a stable, deterministic order.

Sorted by hierarchy path then ID so repeated conversions produce identical
output, which matters for keeping a converted Org file under version control."
  (sort (hash-table-keys index)
        (lambda (a b)
          (let ((ha (omnifocus-hierarchy-safe index a))
                (hb (omnifocus-hierarchy-safe index b)))
            (if (equal ha hb) (string< a b) (string< ha hb))))))

(defun omnifocus-project-ids (index)
  "Return the IDs of the real projects in INDEX, in a deterministic order.

A project is a task whose <project> child is populated (see
`omnifocus-task-record').  In the export every project is top-level, so they
become the level-1 headings of the converted tree."
  (sort (seq-filter (lambda (id) (plist-get (gethash id index) :is-project))
                    (hash-table-keys index))
        (lambda (a b)
          (string< (plist-get (gethash a index) :name)
                   (plist-get (gethash b index) :name)))))

(defun omnifocus-done-p (index id)
  "Return non-nil when the task ID in INDEX is completed.

Completed items are pushed to the bottom of their list, so that the work still
outstanding is what you see first."
  (let ((record (gethash id index)))
    (and record (plist-get record :completed) t)))

(defun omnifocus-inbox-ids (index)
  "Return the IDs of inbox items in INDEX, in a deterministic order.

Completed items sort last so open inbox items stay at the top."
  (sort (seq-filter (lambda (id) (plist-get (gethash id index) :is-inbox))
                    (hash-table-keys index))
        (lambda (a b)
          (let ((da (omnifocus-done-p index a))
                (db (omnifocus-done-p index b)))
            (cond ((and da (not db)) nil)
                  ((and db (not da)) t)
                  (t (string< (plist-get (gethash a index) :name)
                              (plist-get (gethash b index) :name))))))))

(defun omnifocus-children-of (index parent-id)
  "Return the IDs of tasks in INDEX whose parent is PARENT-ID.

Completed tasks sort last, so the open work in a project comes first.  Within
each of those two groups the order is the task's OmniFocus rank when present (a
signed integer string, so this preserves the user's manual ordering), falling
back to the name and then the ID so that output stays deterministic."
  (sort (seq-filter (lambda (id)
                      (equal parent-id (plist-get (gethash id index) :parent-id)))
                    (hash-table-keys index))
        (lambda (a b)
          (let* ((da (omnifocus-done-p index a))
                 (db (omnifocus-done-p index b))
                 (ra (plist-get (gethash a index) :rank))
                 (rb (plist-get (gethash b index) :rank))
                 (na (or (plist-get (gethash a index) :name) ""))
                 (nb (or (plist-get (gethash b index) :name) "")))
            (cond ((and da (not db)) nil)
                  ((and db (not da)) t)
                  ((and ra rb (not (equal ra rb))) (string< ra rb))
                  ((not (equal na nb)) (string< na nb))
                  (t (string< a b)))))))

(defun omnifocus--format-branch (index tag-index parent-id level)
  "Render the children of PARENT-ID in INDEX at Org LEVEL, recursively.

TAG-INDEX supplies heading tags.  Returns a string, possibly empty when
PARENT-ID has no children."
  (mapconcat (lambda (id)
               (concat (omnifocus-format-entry index id tag-index level)
                       (omnifocus--format-branch index tag-index id (1+ level))))
             (omnifocus-children-of index parent-id)
             ""))

(defun omnifocus-convert-index (index &optional tag-index)
  "Convert every task in INDEX into an Org-mode string as a real tree.

Projects (and a synthetic `omnifocus-inbox-label' heading, when there are inbox
items) become level-1 headings; their actions and inbox items are nested as
level-2 headings.  A project with no actions still appears, as a bare heading.

The Inbox heading is emitted first, so unsorted next actions sit at the top of
the file rather than after every project.

TAG-INDEX, when supplied, is a cons as returned by `omnifocus-tag-index' and
supplies the Org tags for each heading."
  (let ((projects (omnifocus-project-ids index))
        (inbox (omnifocus-inbox-ids index)))
    (concat
     ;; Inbox items have no project by construction, so give them a home of
     ;; their own rather than leaving them loose at the top level.  It goes
     ;; first because it is the capture surface - the least sorted, most
     ;; immediate work should not require scrolling past 16 projects.
     (when inbox
       (concat (format "* %s\n" omnifocus-inbox-label)
               (mapconcat (lambda (id)
                            (omnifocus-format-entry index id tag-index 2))
                          inbox
                          "")))
     (mapconcat (lambda (id)
                  (concat (omnifocus-format-entry index id tag-index 1)
                          (omnifocus--format-branch index tag-index id 2)))
                projects
                ""))))

(defun omnifocus-convert-root (root)
  "Convert the parsed OmniFocus ROOT DOM node into an Org-mode string.

This is the pipeline minus parsing: index tasks and tags, then emit the Org
tree.  Callers that already hold a DOM node should use this directly."
  (omnifocus-convert-index (omnifocus-index root)
                           (omnifocus-tag-index root)))

(defun omnifocus-convert-file (file)
  "Convert the OmniFocus XML export at FILE into an Org-mode string.

This is the whole pipeline: parse, index tasks and tags, then emit the Org tree."
  (omnifocus-convert-root (omnifocus-parse-file file)))

(defcustom omnifocus-output-buffer-name "*OmniFocus*"
  "Name of the buffer created by `omnifocus-convert-buffer'."
  :type 'string)

(defun omnifocus--display-output (org &optional source)
  "Put the converted ORG string into `omnifocus-output-buffer-name' and show it.

Returns the output buffer.  The buffer is erased first, so converting twice
reuses it rather than appending a second copy.

When SOURCE is a buffer visiting a file, the output buffer's
`default-directory' is set to that file's directory, so that saving the result
under a relative name puts it next to the export.  SOURCE may also be a
directory name; when it is nil the output buffer simply inherits whatever
`default-directory' is current."
  (let ((out (get-buffer-create omnifocus-output-buffer-name))
        (dir (cond ((bufferp source)
                    (with-current-buffer source
                      (and buffer-file-name
                           (file-name-directory buffer-file-name))))
                   ((stringp source) source)
                   (t nil))))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert org)
        (goto-char (point-min))
        ;; `org-mode' can leave the buffer read-only depending on
        ;; `org-startup-readonly', so make sure the result is editable.
        (org-mode)
        (setq buffer-read-only nil)
        (when dir
          (setq default-directory (file-name-as-directory dir)))))
    (pop-to-buffer out)
    out))

(defun omnifocus-convert-buffer (&optional buffer)
  "Convert the OmniFocus XML export in BUFFER into Org in a new buffer.

BUFFER defaults to the current buffer, which may be visiting the export on
disk or holding it unsaved.  The Org result is written to a fresh buffer named
`omnifocus-output-buffer-name' in `org-mode', and that buffer is returned.

The source buffer is left untouched and no file is written, so this is the
interactive counterpart to `omnifocus-convert-file'.  When the source is
visiting a file, the output buffer's `default-directory' is set to that file's
directory."
  (interactive)
  (let ((source (or buffer (current-buffer))))
    (omnifocus--display-output
     (omnifocus-convert-root (omnifocus-parse-buffer source))
     source)))

(defun omnifocus-convert-region (start end &optional buffer)
  "Convert the OmniFocus XML export between START and END into a new buffer.

Like `omnifocus-convert-buffer', but only the region is parsed, so this works
on a buffer that holds more than one document.  BUFFER defaults to the current
buffer and is where START and END are interpreted.  The output buffer's
`default-directory' follows the same rule as `omnifocus-convert-buffer'."
  (interactive "r")
  (let* ((source (or buffer (current-buffer)))
         (xml (with-current-buffer source
                (buffer-substring-no-properties start end))))
    (omnifocus--display-output
     (omnifocus-convert-root
      (with-temp-buffer
        (insert xml)
        (car (last (xml-parse-region (point-min) (point-max))))))
     source)))

(provide 'omnifocus-convert)
;;; omnifocus-convert.el ends here
