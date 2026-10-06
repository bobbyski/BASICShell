# BASIC project recipes

The recipes every tool makes BASIC projects from: BASICStudio's New Project
wizard, `basicc new`, OmniClide and Freebird Studio (BASIC-24). Each folder
here is one recipe, in OmniClide's `recipe.json` form; the number in front
of a folder's name is only the order the wizard lists them in.

```text
  03-game/
    recipe.json      what it is called, what it makes, what to open
    src/main.bas     every other file is a file the project gets
  _shared/           files every recipe gets, unless it has its own
    Makefile           at the same path: the Makefile, .gitignore,
    project.json       README.md, and the manifest naming the program
```

A recipe makes `Name.basproj`, a folder whose `project.json` names the file
the program starts with (`"entry": "src/main.bas"`).

## recipe.json

| Field | |
|---|---|
| `identifier` | Unique: `basic.game`. `basicc new --kind game` finds it by the part after `basic.`. |
| `name` | Its name in a list of recipes. |
| `language` | `BASIC`. |
| `summary` | A sentence or two on what it makes. |
| `icon` | An SF Symbol, where a tool shows icons. |
| `folderExtension` | `basproj`, so the project is `Name.basproj`. |
| `openFile` | The file to open once the project is made. |
| `postNote` | Said once the project is made. |
| `options` | Values to ask for: `{ "key", "prompt", "defaultValue" }`, or with `"checkedValue"` a checkbox. |

In every file's path and text, `{{NAME}}` is the project's name,
`{{NAME_LOWER}}` the same in lower case, and `{{KEY}}` an option's value.

## After changing a recipe

The recipes are compiled into each tool, so none has a folder to find at run
time. Write the catalog again, in `Code/BASICRecipes`:

```sh
swift run basic-recipe-catalog
```

The tests fail while the catalog and these folders differ.

A user's own recipes are folders like these, which a tool reads where it
keeps them; one with a built-in recipe's identifier is left out.
