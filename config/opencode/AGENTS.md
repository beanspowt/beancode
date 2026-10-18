# User preferences

## File organization (Downloads and similar directories)

The user's preferred scheme, derived from a manual reorganization they did
on `%USERPROFILE%\Downloads`. Follow this rather than naive
extension-based sorting.

### Core principle

Sort **loose files** by type. Never reach inside a **package** — a folder
that is meaningful as a unit — to redistribute its contents.

### Categories

```
Documents\  PDF, Word, Excel, PowerPoint, Text
Images\     JPG, PNG, GIF, SVG
Archives\   ZIP, RAR, 7Z
Installers\ EXE, MSI, plus intact package folders as siblings
Videos\  Audio\  CAD\  Miscellaneous\  Duplicates\
```

Create a subcategory folder **only when it has content**. No empty
scaffolding.

### Packages stay intact

Extracted installer folders (e.g. PSAppDeployToolkit layouts containing
`Deploy-Application.exe`, `setup.exe`, `AppDeployToolkit\`, `Files\`,
`SupportFiles\`) move **whole** into `Installers\`, as siblings of
`Installers\EXE\`. Their internal files are never re-sorted by extension.

Data/project folders move **whole** into `Miscellaneous\`.

`Installers\EXE\` is only for standalone single-file installers.

### No Code category

The user does not want a `Code\` folder. Saved web pages and their
`*_files\` sidecar folders are treated as junk and deleted, not filed.
Code-like files that belong to a package stay inside that package.

### Other rules

- Root directory ends up empty except `desktop.ini`.
- Windows system files (`desktop.ini`, `thumbs.db`) are never moved.
- Directories in active use (e.g. `opencode-windows-x64\`) stay at root,
  not filed into `Installers\`.
- Keeping both an archive and its extracted copy is intentional. Do not
  propose deleting extracted folders to reclaim space.
- Duplicates are quarantined in `Duplicates\`, never auto-deleted.
- Reports and logs are disposable; the user deletes them after reading.

### Workflow

Always dry-run first and show the proposed moves. Never move files without
explicit approval. Never delete anything without explicit approval.
