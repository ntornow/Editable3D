# Editable3D — agent guide

Editable3D is a Luau library for creating and editing 3D content on Roblox with `EditableMesh` and `EditableImage`. It covers mesh modeling, sculpting, UVs, baking, procedural textures and publishing.

## Goal (user, 2026-10-04)
Make Editable3D a strong toolkit for building **complex 3D objects** on Roblox:
- Improve the APIs.
- Keep the agent skills (`.claude/skills/`) current, so agents can do sophisticated modeling and texturing reliably.

Real projects that use the library drive the priorities:
- When an application needs ad-hoc code for a general operation, add the operation here, with tests and docs.
- When the engine behaves unexpectedly, add the lesson to the `editable3d-studio` skill.

## Rules
- This repo is only the library. Keep it free of references to the projects that use it.
- Every change:
  - add or adjust tests in `tests/`
  - run `python3 tools/validate.py`, which includes headless suites, strict typing and the API reference
  - add a CHANGELOG entry and bump the version
- New public modules are `--!strict` and listed in `STRICT_MODULES` (`tools/check_types.py`).
- Release to Studio through the verify, then install, flow in `.claude/skills/editable3d-studio/SKILL.md` and `MAINTAINING.md`.
- MIT licensed. Don't add third-party code or assets.

## Where things are
- `src/`: modules, with namespaces wired in `src/init.luau`
- `tests/`: suites, plus `headless-baseline.json`
- `tools/`: headless runner (Lune), validators, Studio verify and install scripts
- Topic guides: the `*.md` files at the root
- `API.md`: the generated API reference
