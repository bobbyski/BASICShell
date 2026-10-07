# Projects

![BASICStudio](https://img.shields.io/badge/BASICStudio-supported-brightgreen)

A program that grows past one file becomes a project: a folder of `.bas` files that `IMPORT` each other, with one of them the file the program starts in.

## What a project is

A project is a folder whose name ends in `.basproj`:

```text
  Asteroids.basproj/
    project.json      the program's name, and the file it starts in
    src/main.bas      where the program starts
    src/Ship.bas      a module main.bas IMPORTs
    Makefile          make builds it with basicc
    README.md
    .gitignore
```

`project.json` names the file the program starts in:

```json
{
  "schemaVersion": 1,
  "kind": "project",
  "name": "Asteroids",
  "entry": "src/main.bas"
}
```

Change `entry` to start somewhere else. Without one, Studio starts in `src/main.bas`, then `Sources/main.bas`, then `main.bas`, whichever it finds first.

The other files are the program's modules. See [IMPORT](IMPORT.md).

## Starting a project

Choose **File ▸ New Project…** (⇧⌘N). On iPad, it is in the **···** menu, under **File**.

1. **Choose a recipe.** Each one is a working program to start from. The summary under the list says what it makes, and the line under that lists its files.
2. **Name the project.** The name is letters, digits, `-` and `_`. The project is `Name.basproj`.
   - On the Mac, it goes beside the project that is open, or in the working directory. **Choose…** puts it somewhere else.
   - On iPad, it goes in the Documents folder Studio works in.
3. **Options.** Only a recipe that asks for something has this page.
4. **Create.** Studio makes the project, opens it in the sidebar, and puts the file it starts in into the editor. Press **Run**.

Create stays off while the name is not a name, or a project of that name is already there. The line under the name says which.

| Recipe | What it makes |
| --- | --- |
| Console Program | One file that prints, loops and reads what is typed. |
| Structured Program | FUNCTIONs with their own LOCALs, arrays and DATA. |
| Game | Someone to move around and four targets to shoot: they turn to face the way you point and walk, run when you point harder, and fire the way they face, with the keyboard, a gamepad or touch. |
| TUI App | A full-screen TUIKit window with a menu bar, a field, a list and buttons. |
| ActiveUI App | A to-do list in a window of its own: buttons, a field, a list and a status line. Runs in BASICStudio. |
| Contact Book | A TUIKit contact book in six files: a model, JSON save and load, a toolbar and menus, and an unsaved-changes dialog. |
| TUIKit Gallery | Every TUIKit control in one application, one file per group of them. |

## Opening a project

- **File ▸ Open Project…** opens a `.basproj` folder, or any folder of `.bas` files.
- **File ▸ Open Recent** lists the projects and the files opened lately, newest first, ten of each, and opens one again. A file picked in the project sidebar is not added: the project already is. **Clear Menu** empties it.
- **Examples** that are projects open as projects. Studio opens a copy, so the example itself is never changed:
  - On the Mac, the copy is in `Documents/BASICStudio Examples`.
  - With iCloud on, the copy is in the `Examples` folder of Studio's iCloud folder.
  - On iPad, the copy is in `Documents/Examples`.

  Opening the example again opens your copy as you left it. Delete the copy to start over.

## The same project everywhere

BASICStudio, `basicc new`, OmniClide and Freebird Studio make projects from the same recipes. A project made in one opens in the others:

```sh
basicc new Asteroids --kind game     # makes Asteroids.basproj
basicc build Asteroids.basproj       # builds the program it names
cd Asteroids.basproj && make run     # or build and run with its Makefile
```

## Adding your own recipe

A recipe is a folder with a `recipe.json` in it. Every other file in the folder is a file the project gets. Put the folder in Studio's recipes folder:

- **Mac:** `~/Library/Application Support/AIBasic/Recipes`
- **iPad:** `Documents/Recipes`, which the Files app can reach.

```text
  Recipes/
    quiz/
      recipe.json
      project.json
      src/main.bas
    _shared/          files every recipe here gets, unless it has its own
      README.md
```

`recipe.json`:

```json
{
  "identifier": "my.quiz",
  "name": "Quiz",
  "language": "BASIC",
  "summary": "Asks ten questions and keeps score.",
  "icon": "questionmark.circle",
  "folderExtension": "basproj",
  "openFile": "src/main.bas",
  "postNote": "created — press Run"
}
```

| Field | |
| --- | --- |
| `identifier` | Unique. A recipe with a built-in one's identifier is left out. |
| `name` | Its name in the list of recipes. |
| `summary` | A sentence or two shown under the list. |
| `icon` | An SF Symbol for the list. |
| `folderExtension` | `basproj`, so the project is `Name.basproj`. |
| `openFile` | The file Studio puts in the editor once the project is made. |
| `options` | Values to ask for, on the Options page: `{ "key": "TITLE", "prompt": "Title", "defaultValue": "Quiz" }`. Add `"checkedValue"` for a checkbox, which fills its key with that value when checked and with nothing when not. |

In every file's path and text, `{{NAME}}` becomes the project's name, `{{NAME_LOWER}}` the same in lower case, and `{{KEY}}` an option's value:

```basic
' {{NAME}}: a quiz.
PRINT "Welcome to {{TITLE}}!"
```

Give the recipe a `project.json` with `"entry"`, so the project says where it starts:

```json
{ "schemaVersion": 1, "kind": "project", "name": "{{NAME}}", "entry": "src/main.bas" }
```

The next **File ▸ New Project…** lists it after the built-in recipes.

OmniClide reads a recipe folder like these from its own recipes folder, `~/.omegaCLIDE/recipes`. It has no `_shared` folder, so each recipe there carries all its files.
