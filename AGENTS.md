# Project Overview: OmniFocus XML to Org-Mode Converter

## 1. Project Goal
Convert OmniFocus export XML data (`contents.xml`) into Emacs Org-mode format using Emacs Lisp and built-in Emacs capabilities.

The pipeline is **implemented and verified** in `omnifocus-convert.el`:

1. Parse the XML with Emacs built-in tools.
2. Index every task by `id` into a hash table.
3. Resolve the parent-child hierarchy (used to nest headings and to order them).
4. Index tags (from the `<task-to-tag>` join) into escaped Org tags.
5. Emit the result as a **real Org tree**: projects as level-1 headings, their
   actions as level-2 headings, plus a synthetic `Inbox` heading. Dates become
   Org `SCHEDULED:` / `DEADLINE:` planning lines.

Do not attempt to load `contents.xml` into context. Use `xmlstarlet` or standard search tools to explore it.

### How to verify against a real export
Rather than trusting a fixed set of numbers (they change with every export), verify
the output against the XML it came from. The following relationships must hold for
*any* export, and each is cheap to check:

| Relationship | How to check |
| --- | --- |
| Every `<task>` with an `id` yields exactly one heading | compare `count(//task[@id])` with the heading count |
| Every heading has an `:OMNIFOCUS_ID:` | count the property lines; must equal the heading count |
| Every project is a level-1 heading; actions and inbox items nest beneath | depth follows the export's own nesting, so don't assume exactly two levels |
| Each populated `<start>` yields one `SCHEDULED:`, each `<due>` one `DEADLINE:` | see the `and text()` guard in section 5 |
| Each `<task-to-tag>` row's tag appears on its task's heading | tag tokens ≥ join rows, since a heading lists several tags on one line |
| Parent references all resolve | count `<task idref>` values with no matching `@id`; should be 0 |

**Do not hard-code counts.** The only structural constant is that a task's parent
is either a project or another task, and inbox items have no parent. Everything
else — how many projects there are, how deep the tree goes, how many tags exist
and how they are named — is user data and will differ between exports.

One thing that *is* worth knowing up front: real exports are typically shallow.
Nested sub-projects and nested sub-tasks exist in the schema and the converter
handles them generically, but a typical file has every action parented directly to
a project, giving a two-level tree. Do not assume that shape, though — the
converter must keep working when it is deeper.

---

## 2. Input Data & Structure

### Files
- **`contents.xml`**: The full OmniFocus export database (~2 MB, ~65,500 lines). Not to be dumped or inspected directly in large chunks.
- **`omnifocus-convert.el`**: The implementation.

### Validate against real data
When you need a sample to test with, extract one from the real export with
`xmlstarlet` rather than hand-writing it, and discard it once it has served its
purpose. A hand-made extract tends to be lossy in ways that are hard to notice:
dropping `<name>`, `<added>` or `<task/>` from a record can make an ordinary
project look like an unnamed, parentless anomaly and manufacture a dangling-parent
case that does not exist in real data.

Every task in a well-formed export has both `<name>` and `<added>`.

### Data Model & XML Schema
- **Root Element**: `<omnifocus xmlns="http://www.omnigroup.com/namespace/OmniFocus/v2" ...>`
- **Core Entities**:
  - `<task id="...">`: Represents both projects and individual tasks/actions.
  - `<project>`:
    - If non-empty (e.g. contains `<status>`, `<singleton>`, `<last-review>`), the containing `<task>` is a **Project**.
    - If self-closing (`<project/>`), the containing `<task>` is an action/task.
  - `<inbox>`:
    - `<inbox>true</inbox>`: Item belongs to the Inbox (no assigned project).
    - `<inbox>false</inbox>`: Item is assigned to a project or parent task.
  - `<task idref="..."/>`: Points to the parent `<task>` (either a project or a parent task in a subtask hierarchy). If self-closing `<task/>`, the item has no parent task (it is either a top-level project or an inbox item).
  - `<name>`: The title of the project or task. **May contain newlines** (see traps).
  - `<note>`: Multi-line rich text note or description.
  - Other task metadata: `<added>`, `<modified>`, `<start>`, `<due>`, `<completed>`, `<flagged>`, `<repetition-rule>`, `<estimated-minutes>`, `<rank>`.
  - `<context idref="..."/>` / `<context>`: **tags** (see section 3). This child is always
    present on a `<task>`, but is self-closing and empty for untagged tasks.
  - `<task-to-tag>`: the tag-join table (see section 3); the authoritative source of tags.
  - Elements to ignore for now: `<attachment>`, `<perspective>`, `<setting>`.

### Traps confirmed against real data

**The parent reference has three states, not two.** The presence of the `<task>`
child is itself meaningful, so do not normalise it away:

| Child element | Meaning |
| --- | --- |
| `<task/>` | Top-level item, no parent |
| `<task idref="X"/>` | Parent is `X` |
| *(absent)* | Does not occur |

An `xml.el` walk must therefore distinguish "self-closing" from "populated"; a
parser that flattens the tree cannot.

**The `<task>` element name is overloaded.** `<attachment>` and `<context>`
elements also contain `<task idref="..."/>` children, so a naive count or search
for `<task>` returns many more matches than there are real tasks. Iterate the raw
tree and filter on the presence of an `id` attribute.

**`dom.el` accessors do not fit `xml.el` nodes.** `xml-parse-file` yields raw
`(TAG ATTRS CHILD...)` lists. `dom-attr` misreads the flat attribute alist
(`((idref . "X"))`), and `dom-by-tag` flattens the tree so that a self-closing
`<project/>` becomes indistinguishable from a populated `<project>`. Walk the list
structure directly. Note `(car (last dom))` is needed to reach the root element,
and node tags are matched without namespace prefixes.

**Timestamp conventions differ by field.** This is a correctness trap, not a
per-file quirk — it holds for the schema as a whole:

| Field | Convention |
| --- | --- |
| `added`, `modified`, `completed` | true UTC instants, always ending in `Z` |
| `start`, `due` | *local* wall-clock, never carrying a zone |

A `start`/`due` value such as `2026-04-22T00:00:00.000` means midnight local.
Parsing it as UTC shifts it by the UTC offset (turning midnight into `05:30` at
UTC+05:30). Convert `Z` stamps into local time; render zone-less stamps verbatim.

**`<name>` may contain newlines.** The title field can be used as free text,
holding several sentences separated by newlines. An Org heading cannot span lines:
a stray newline makes the remainder parse as a new heading and detaches the
property drawer. Collapse whitespace runs in names to single spaces.

**`xmlstarlet` notes:** `--var` is unsupported in this build, and self-referential
XPath using `current()` with nested reverse lookups is pathologically slow here
(it hung). Prefer plain XPath, or evaluate Emacs Lisp instead.

**Tag traps (see section 3).** Tags are `<context>` elements, not `<tag>` elements.
A `<task>`'s own `<context>` child holds *only its first tag*, so deriving tags
from it silently loses any additional tags. Also note every `<task>` has a
`<context>` child even when untagged (self-closing, no `idref`), so a bare
"has a `<context>` child" test matches every task rather than only the tagged ones.

**Org tag character set.** Org accepts only `[[:alnum:]_@#%]` in a tag and
**silently splits on whitespace**, so an unescaped `:London Team:` becomes two
tags (`London`, `Team`) and `/` is not a legal character at all. Tag paths must
therefore be flattened (see section 3) — a raw path pasted into a heading would
produce wrong tags with no error.

---

## 3. Tagging

In OmniFocus 4, tags and the legacy "context" concept are unified: a tag is a
`<context>` element and tag assignment is a many-to-many `<task-to-tag>` join.
This section records the verified mechanism and how `omnifocus-convert.el`
emits tags.

### The mechanism: tags are `<context>` elements, joined via `<task-to-tag>`

**There are zero `<tag>` elements** in the export. In OmniFocus 4 the old
"context" concept was merged into tags, so a tag **is** a `<context>` element and
tag assignment is a many-to-many join table.

Relevant top-level children of `<omnifocus>` are `task`, `context`,
`task-to-tag`, `attachment`, `setting` and `perspective`.

| Element | Role |
| --- | --- |
| `<context>` | **tag definitions** |
| `<task-to-tag>` | **join rows** linking a task to a tag |

### The join record

```xml
<task-to-tag id="hGjkmwV9ijL.plxGv3egdNc">
  <added order="1">2025-01-30T12:54:22.908Z</added>
  <task idref="hGjkmwV9ijL"/>      <!-- the tagged task -->
  <context idref="plxGv3egdNc"/>   <!-- the tag -->
  <rank-in-task>f09c</rank-in-task>
  <rank-in-tag/>
</task-to-tag>
```

- Its `id` is a **composite join key** `"<task-id>.<context-id>"`.
- `<task>`/`<context>` use **`idref` attributes**, so read them by raw alist lookup
  (`(cdr (assq 'idref (cadr node)))`), **never** `dom-attr` (see the `dom.el` trap).
- `<rank-in-task>` orders this tag within its task. `<rank-in-tag/>` is present but
  observed **always empty**, so treat it as carrying no usable data — though since
  it is a rank field, a future export could populate it.
- Some rows also carry `<modified>`, and `<added>` may carry an `order` attribute;
  neither is needed for conversion.
- The `<context>` child of a task is **never absent** — it is either
  present-but-empty (`(context nil)`) or present-with-`idref`, so a bare
  "has a `<context>` child" test matches every task, not just the tagged ones.

### The `<context>` child on a task is redundant — the join is authoritative

Every `<task>` has a `<context>` child, but it is **usually self-closing and empty**
(`(context nil)`). When it carries an `idref`, that set is **exactly** the set of
tasks appearing in `task-to-tag`. Specifically:

- The task's own `<context idref="X"/>` is **always one of** that task's join rows,
  and specifically **always the first in file order**. It is a denormalised cache
  of the *primary* tag, not an independent field.
- Tasks can have **more than one tag**, and for those the extra tags exist **only**
  in `task-to-tag` — reading the task's `<context>` child silently drops them.

**Therefore: build the task → tags mapping from the `task-to-tag` rows, not from
the `<context>` child of each task.**

### The tag namespace is hierarchical

Each `<context>` has its own `<context>` child (a parent reference), so tags form a
tree and render as paths (`People/Lakshika`). Depth is not fixed: expect at least
two levels, and code for more. Tags are typically `hidden`; do not rely on that
flag.

Notes:
- A context may be defined but never referenced by a join row; don't assume every
  definition is used.
- A context may have an **empty `<name/>`**, i.e. a tag with no name; guard against
  blank tag names.
- Usage is typically highly skewed — a handful of tags carry most assignments — so
  do not infer importance from a tag's position in the tree.
- Namespace names are arbitrary user text and mix categories freely (project-ish
  groupings, person names, and so on), reflecting the OmniFocus 4 context/tag merge.
  Never hard-code tag names or assume a fixed vocabulary.

### Representation in Org output: flattened Org tags

Tags are emitted as **native Org tags** on the heading line. Because Org accepts
only `[[:alnum:]_@#%]` in a tag and splits on whitespace, each tag path is
**flattened**: runs of `/` and whitespace become `_`, and any remaining illegal
character is dropped (`omnifocus--escape-tag`). Ancestors are *not* emitted as
separate tags unless `omnifocus-tag-inherit-groups` is enabled.

The illustrative mapping (real names, but any export will have its own):

| OmniFocus tag path | Emitted Org tag |
| --- | --- |
| `People/Lakshika` | `People_Lakshika` |
| `Meetings/Residence Maintainance` | `Meetings_Residence_Maintainance` |
| `People/Naughty Daughter` | `People_Naughty_Daughter` |
| `London Team` | `London_Team` |
| `Entertain` | `Entertain` |

Collisions are possible in principle — flattening is lossy, so two different paths
can map to the same tag. The converter does not currently detect or report this;
the escape function is pure and deterministic, so if a collision matters, check for
one by comparing the escaped-tag count against the distinct-path count. The `:inbox:`
tag is still appended for inbox items, so a tagged inbox item carries both.

Example output (note the real Org nesting — project at level 1, action at level 2):

```
* Project Name
:PROPERTIES:
:OMNIFOCUS_ID: ...
:END:
** DONE An action with two tags :Group_First:Group_Second:
:PROPERTIES:
:OMNIFOCUS_ID: ...
:END:
```

**This mapping is deliberately lossy.** `People_Naughty_Daughter` cannot be
reversed to `People/Naughty Daughter` — Org has no tag hierarchy, so `People`
and `People_Lakshika` are unrelated tags and grouping is by prefix convention
only. If a round-trip back to OmniFocus is ever needed, the full path must also
be written to a drawer property.

### Implementation

| Function | Role |
| --- | --- |
| `omnifocus-tag-index` | Returns `(TASK-TAGS . CONTEXTS)`; `TASK-TAGS` maps task ID → list of context IDs (from `<task-to-tag>`), `CONTEXTS` maps context ID → `(NAME . PARENT-ID)` |
| `omnifocus-tags` | Raw context IDs for a task |
| `omnifocus-tag-path` / `-safe` | Context ID → `"People/Lakshika"`, cycle-guarded |
| `omnifocus--escape-tag` | Path → legal Org tag (the `_` rule above) |
| `omnifocus-format-tags` | Task ID → `" :a:b:"` heading suffix, or `""` |

`omnifocus-format-entry` takes an optional third argument (the tag index) and
`omnifocus-convert-file` builds it automatically. Relevant defcustoms:
`omnifocus-tag-separator` (`"/"`), `omnifocus-tag-inherit-groups` (nil),
`omnifocus-max-tag-depth` (16).

---

## 4. Architecture & Implementation

The plan below is implemented in `omnifocus-convert.el` (all five steps complete
and verified). Corrections found during implementation are folded in.

### Step 1: Built-in XML Parsing
- **`libxml-parse-xml-region` is *not* available** in this Emacs build (31.1,
  emacs-plus) — `(fboundp 'libxml-parse-xml-region)` is nil. Use `xml-parse-file`
  from `xml.el` instead.
- **Do not use `dom.el` utilities** (`dom-by-tag`, `dom-attr`, `dom-text`,
  `dom-children`): they do not fit the raw `xml.el` node shape, and `dom-text` is
  obsolete as of Emacs 31.1. Walk the `(TAG ATTRS CHILD...)` lists directly.
- Entry points: `omnifocus-parse-file`, then `omnifocus-index`.

### Step 2: In-Memory Indexing
- Traverse all `<task>` nodes and store each in a hash table keyed by its `id`:
  - `:id`, `:name` (whitespace-collapsed), `:parent-id` (from `<task idref>`)
  - `:is-project` (true when `<project>` has child elements)
  - `:is-inbox` (true when `<inbox>` is `"true"`)
  - `:note`, `:added`, `:modified`, `:start`, `:due`, `:completed`, `:flagged`,
    `:estimated-minutes`, `:repetition-rule`, `:rank`
- Entry points: `omnifocus-task-nodes`, `omnifocus-task-record`, `omnifocus-index`,
  `omnifocus-task`.

### Step 3: Hierarchy Resolution
- Follow `parent-id` to the root to establish ancestry. The names are joined into
  a breadcrumb path (`"Project/Sub-Project/Action"`), but that
  path is now used **only for ordering** — it is no longer written to the output,
  because the Org tree itself expresses the hierarchy.
- Inbox items have no parent by construction, so they are rooted at
  `omnifocus-inbox-label` for classification and ordering purposes.
- Robustness: a parent missing from the document ends the walk gracefully
  (it means a partial extract); a referential cycle signals an error rather than
  looping forever; `omnifocus-hierarchy-safe` converts any error to a diagnostic
  string so one bad record cannot abort an export.
- Entry points: `omnifocus-ancestry`, `omnifocus-hierarchy`, `omnifocus-hierarchy-safe`.

### Step 4: Tag Resolution
- Build the tag tables with `omnifocus-tag-index`: task ID → context IDs comes from
  the **`<task-to-tag>` join rows** (authoritative), and context ID → `(NAME . PARENT-ID)`
  comes from the `<context>` definitions. See section 3 for why the task's own
  `<context>` child must *not* be used.
- Resolve each context ID to a path (`People/Lakshika`) with `omnifocus-tag-path`,
  cycle-guarded like the hierarchy walk, then flatten it to a legal Org tag with
  `omnifocus--escape-tag`.
- Entry points: `omnifocus-tag-index`, `omnifocus-tags`, `omnifocus-tag-path`,
  `omnifocus-tag-path-safe`, `omnifocus-format-tags`.

### Step 5: Org Property Drawer Output
- The output is a **real Org tree**, not a flat list:
  - **Level 1** (`*`) = the projects, plus a synthetic `* Inbox` heading
    (from `omnifocus-inbox-label`) emitted only when inbox items exist.
  - **Level 2+** (`**`, `***`, …) = actions nested under their project, and inbox
    items nested under `Inbox`. The converter recurses, so a sub-project or a
    sub-task simply adds another level.
  - A project with no actions still appears as a bare heading.
- Each heading is its name plus Org tags, then an optional **planning line**, then
  a property drawer containing:
  - `:OMNIFOCUS_ID:`
  - `:ADDED:`, `:MODIFIED:`, `:COMPLETED:`, `:FLAGGED:`
  - `:ESTIMATED_MINUTES:`, `:REPETITION_RULE:`
- **OmniFocus dates map to real Org planning info.** `<start>` (OmniFocus's *defer*
  date) becomes `SCHEDULED:` and `<due>` becomes `DEADLINE:`, emitted as active
  timestamps on the line between the heading and the drawer:

  ```org
  ** TODO An action with a defer date
  SCHEDULED: <2025-11-27 Thu 00:00>
  :PROPERTIES:
  :OMNIFOCUS_ID: ...
  :END:
  ```

  When a task has both, they share one line (`SCHEDULED: <...> DEADLINE: <...>`),
  which is the form Org requires. There are **no `:START:` or `:DUE:` drawer
  properties** — putting planning data in the drawer makes it inert (invisible to
  the agenda), which is exactly the bug this replaced.
- Both dates are local wall-clock values in the export and are rendered verbatim
  (see the timestamp trap in section 2): `start`/`due` never carry a `Z`, unlike
  `added`/`modified`/`completed`.
- **There is no `:HIERARCHY:` property.** It was removed when the tree was
  introduced: the heading's position in the outline now carries that information,
  and repeating it in the drawer would be redundant.
- Properties with no value are **omitted entirely**, so self-closing elements
  such as `<due/>` leave no trace in the drawer.
- Conventions chosen during implementation (not in the original spec): projects get
  no TODO keyword, actions get `TODO`/`DONE`, inbox items are tagged `:inbox:`, and
  OmniFocus tags become flattened Org tags (see section 3).
- Output is deterministically ordered so repeated conversions produce
  byte-identical files, which matters under version control. Within a list,
  completed items sort **last** so outstanding work is seen first; within each of
  those two groups, children are sorted by their OmniFocus `:rank` then name then
  ID, projects by name, and inbox items by name.
- Entry points: `omnifocus-property-alist`, `omnifocus-format-entry`,
  `omnifocus-project-ids`, `omnifocus-inbox-ids`, `omnifocus-children-of`,
  `omnifocus--format-branch`, `omnifocus-convert-index`, `omnifocus-convert-file`.

---

## 5. Running the Converter

There are four entry points, all in `omnifocus-convert.el`. Pick by where the XML
is coming from and where the result should go:

| Entry point | Input | Output |
| --- | --- | --- |
| `(omnifocus-convert-file FILE)` | a file on disk | Org string |
| `(omnifocus-convert-buffer &optional BUFFER)` | XML in a buffer | **new buffer** in `org-mode` |
| `(omnifocus-convert-region START END &optional BUFFER)` | XML in a region | **new buffer** in `org-mode` |
| `(omnifocus-convert-root DOM)` | an already-parsed DOM | Org string |

The two string-returning functions are the building blocks: `omnifocus-convert-root`
is the pipeline minus parsing, and `omnifocus-convert-file` is
`omnifocus-convert-root` applied to `(omnifocus-parse-file FILE)`. The two
buffer-producing commands wrap the same pipeline and additionally place the result
in a buffer, so all four produce identical Org text from the same input.

`omnifocus-convert-file` reads the file **from disk** via `xml-parse-file`, so
having `contents.xml` open in a buffer (or editing it unsaved) has no effect on the
result. Use `omnifocus-convert-buffer` when you specifically want the *buffer*
contents converted — e.g. the export is unsaved, or its text arrived from somewhere
other than a file. It honours narrowing, so narrow first to convert only part of a
buffer, or call `omnifocus-convert-region` to parse an explicit range.

The buffer-producing commands write to `omnifocus-output-buffer-name` (default
`"*OmniFocus*"`), `pop-to-buffer` it, and return it. The buffer is erased first, so
converting twice reuses it rather than appending a second copy. The source buffer is
left untouched and no file is written. When the source is visiting a file, the
output buffer's `default-directory` is set to that file's directory, so saving the
result under a relative name puts it next to the export.

Note that `let*` bindings do **not** persist between separate `M-:` evaluations;
wrap dependent steps in a single `progn` or use `setq`.

Within Emacs, after `M-x load-file` on `omnifocus-convert.el`:

```elisp
;; insert the converted Org document at point
(insert (omnifocus-convert-file "contents.xml"))

;; or, interactively: M-x omnifocus-convert-buffer with an export in the
;; current buffer, or M-x omnifocus-convert-region on an active region.
```

From the command line:

```bash
# write to a file
emacs --batch --quick -l omnifocus-convert.el \
  --eval '(with-temp-file "/tmp/omnifocus.org" (insert (omnifocus-convert-file "contents.xml")))'

# or pipe to stdout (use princ, not print, which escapes newlines)
emacs --batch --quick -l omnifocus-convert.el \
  --eval '(princ (omnifocus-convert-file "contents.xml"))' > /tmp/omnifocus.org
```

### Verifying output
There are no fixed expected counts — they depend on the export. Instead, verify the
**invariants** that must hold whatever the input:

| Invariant | Why it matters |
| --- | --- |
| Heading count equals `count(//task[@id])` | no task is dropped or duplicated |
| `:OMNIFOCUS_ID:` lines equal the heading count | every heading is traceable |
| `:PROPERTIES:` / `:END:` pairs equal the heading count | no malformed drawer |
| No level jumps (e.g. `*` directly to `***`) | the tree nests correctly |
| `SCHEDULED:` count equals populated `<start>` count | no date silently lost |
| `DEADLINE:` count equals populated `<due>` count | no date silently lost |
| `:START:` / `:DUE:` / `:HIERARCHY:` properties are absent | obsolete forms not reintroduced |
| `nil` appears nowhere | no unformatted value leaked |
| Every tag matches `[[:alnum:]_@#%]+` | no heading-line corruption |

A useful independent check is to load the result with `org-mode` and confirm via
`org-entry-get` that every headline has a non-empty `OMNIFOCUS_ID`, that no
headline has a `HIERARCHY` property, that `org-current-level` never jumps a level,
and that `org-parse-time-string` accepts every `SCHEDULED`/`DEADLINE` value.

Cross-check the date counts with `xmlstarlet`:

```bash
# populated <start> and <due> elements - these are the expected planning counts
xmlstarlet sel -t -v 'count(//*[local-name()="task"]/*[local-name()="start" and text()])' contents.xml
xmlstarlet sel -t -v 'count(//*[local-name()="task"]/*[local-name()="due" and text()])' contents.xml
```

Note the `and text()` guard: every task carries a `<start>` and a `<due>` element,
but only some have content, so counting the bare elements tells you nothing.

---

## 6. Environment Notes (Emacs MCP server)

The Emacs MCP server runs Elisp under a security layer that blocks several
functions; these were the constraints encountered:

- **Blocked:** `insert-file-contents`, `insert-file-contents-literally`,
  `with-current-buffer`, `load`, `eval`, `write-region`, `with-temp-file`, `getenv`.
- **Available:** `load-file`, `xml-parse-file`, `date-to-time`.

Because `load-file` is permitted but `load`/`eval` are not, use `load-file` to
load `omnifocus-convert.el` over MCP. Batch `emacs --batch` invocations from the
shell are not subject to these restrictions.
