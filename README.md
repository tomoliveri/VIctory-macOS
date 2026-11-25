<p align="center"><img src="docs/images/banner.svg" alt="VIctory for macOS: a neon tropical sunset with palm trees, a coastal skyline and a MacBook on the shore"></p>

<h1 align="center">VIctory for macOS</h1>

<p align="center">
Grand Theft Auto VI is only out on consoles. This project runs the Xbox Series build on Apple Silicon Macs, from a copy of the game that you own.<br>
It is built on <a href="https://github.com/Marvisak/VIctory">VIctory</a>, which does the same on Windows, and it brings that work to the Mac through Wine and Metal.
</p>

<p align="center">
<img alt="Apple Silicon M1 or newer" src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-555555">
<img alt="macOS 15 or newer" src="https://img.shields.io/badge/macOS-15%2B-blue">
<img alt="343 tests passed" src="https://img.shields.io/badge/tests-343%20passed-2ea44f">
<img alt="GPL-3.0 licence" src="https://img.shields.io/badge/licence-GPL--3.0-lightgrey">
</p>

<p align="center">
If you want to see GTA VI on a Mac, please star the repo and read <a href="CONTRIBUTING.md">CONTRIBUTING.md</a>. Help is welcome at every level.
</p>

> [!IMPORTANT]
> **The game is not playable yet, on the Mac or anywhere else.** VIctory on Windows boots the game, runs its menus, loads the world and now draws it, but only at one or two seconds per frame and with unlit surfaces and missing geometry. This project makes the whole VIctory platform run on a Mac, so the Mac moves forward as VIctory does. No game files are included here or ever will be. You need your own copy of the game.

## What works today

Every part of VIctory now runs on an Apple Silicon Mac, and its full test suite passes on a MacBook with an M4 chip.

| Part | What it does | On the Mac |
| --- | --- | --- |
| Loader | Maps the game's executable and DLLs into one process and runs its code unchanged | Works |
| Console runtime | Stands in for the Xbox: memory, files, saves, input, audio and network rules | Works |
| GPU layer | Turns the console's Direct3D 12.X into desktop Direct3D 12 | Works on Metal through D3DMetal |
| Shader recompiler | Recompiles the console GPU's shaders, checked against the hardware's results | All 69 checks pass on Metal |
| Test suite | 343 tests across every crate | 343 passed, 0 failed |

<p align="center"><img src="docs/images/tests.svg" width="640" alt="Terminal output of the test suite under CrossOver Wine with D3DMetal on an Apple M4: 343 passed and 0 failed"></p>

This is the real result of a clean run of `./setup.sh` followed by the test suite on a MacBook with an M4 chip.

Getting there took a few Mac-specific fixes, and each one is explained in [docs/macos.md](docs/macos.md). Two of them fixed real bugs that would have broken the picture on screen. Texture uploads were being skipped because Wine cannot see the memory that D3DMetal maps, and Metal's `sin` and `cos` return 0 where the console GPU returns NaN.

## How it works

<p align="center"><img src="docs/images/stack.svg" width="720" alt="The layers between the game and the Mac: the game's code, VIctory, CrossOver Wine and D3DMetal, Rosetta 2 and Metal, and the Apple Silicon Mac at the bottom"></p>

The Xbox Series version of the game is x86-64 code, like a Windows program. VIctory loads that code and supplies everything the console would have supplied. On a Mac, VIctory itself runs as a Windows program:

- **Rosetta 2** runs the x86-64 code, including the AVX2 instructions that the game uses.
- **CrossOver Wine** provides Windows. The setup builds it from the source that CodeWeavers publishes, because Apple's D3DMetal only works with that branch of Wine.
- **D3DMetal**, from Apple's Game Porting Toolkit, turns Direct3D 12 into Metal.

## Set it up in three steps

You need an Apple Silicon Mac (M1 or newer) on macOS 15 Sequoia or newer, [Homebrew](https://brew.sh), and about 15 GB of free space.

**1. Get the code.**

```bash
git clone https://github.com/pragyaangaur/VIctory-macOS.git
cd VIctory-macOS
```

**2. Download Apple's Game Porting Toolkit.** Apple only gives D3DMetal to signed-in developers, so this is the one step nobody can do for you. Open the [Apple developer downloads](https://developer.apple.com/download/all/?q=game%20porting%20toolkit), sign in with any Apple account (a free one works), and download the newest **Game Porting Toolkit** `.dmg`. Leave it in your Downloads folder and do not open it.

**3. Run the setup.**

```bash
./setup.sh
```

The setup installs what it needs with Homebrew. It then builds the x86_64 libraries and CrossOver Wine, adds D3DMetal from the toolkit, and builds VIctory. The first run takes about an hour, almost all of it spent building Wine. If anything stops it, fix what it says and run it again, because finished steps are skipped.

When it says **Setup finished**, you can check that VIctory starts:

```bash
tools/macos/victory.sh config
```

## Running the game

Put your own copy of the Xbox Series build in a folder, set `game_dir` in `victory.toml` to that folder, and start it:

```bash
tools/macos/victory.sh run --execute <the game's executable>
```

For now this gets as far as VIctory does on Windows, as the note at the top explains.

## Running the tests

These commands are useful for anyone who works on the code. The first runs the tests natively on the Mac, and the second runs them as Windows programs on Wine with D3DMetal, which includes the GPU tests.

```bash
cargo test --workspace
```

```bash
WINE="$HOME/Library/Caches/victory-macos/target/wine-cx/bin/wine" WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=b" tools/macos/test-wine.sh --workspace --no-fail-fast
```

## Help test on your Mac

The project needs test results from as many Macs as possible. The [Mac test fleet](docs/fleet.md) runs both test suites on your Mac and reports the counts to this repository. It uses only the project's own tests, never a game. Paste this into an AI coding agent on your Mac, such as Claude Code, Codex or Cursor:

```text
Read https://raw.githubusercontent.com/pragyaangaur/VIctory-macOS/main/docs/fleet-join.md and follow it to help test VIctory on my Mac. Ask me once before installing or posting anything, then keep going until I say stop.
```

Please read [docs/fleet-legal.md](docs/fleet-legal.md) first. You can also run the fleet by hand with `tools/fleet/fleet.sh`.

## Where things are

| Path | What it holds |
| --- | --- |
| `setup.sh` | The one-step setup |
| `tools/macos/` | The Wine build, the library build, the launcher and the test runner |
| `tools/fleet/` | The Mac test fleet: the worker, the issue queue and its tests ([docs/fleet.md](docs/fleet.md)) |
| `docs/macos.md` | The full story of the port, the problems found and how each was fixed |
| `crates/` | VIctory's runtime: loader, console runtime, GPU layer, shader recompiler and formats |
| `docs/architecture.md` | How VIctory itself is put together |

## Acknowledgement

This project is built on top of [VIctory](https://github.com/Marvisak/VIctory) by Marvisak. The loader, the console runtime, the GPU layer and the shader recompiler all come from VIctory, and its full history is kept in this repository. This project adds the macOS side: the Mac build, the Wine and D3DMetal setup, and the fixes that the Mac needed. VIctory is licensed under GPL-3.0, so this project is too.

Thanks also go to CodeWeavers for publishing CrossOver's source, to the Wine project, and to Apple for the Game Porting Toolkit.

## Legal

This project is not affiliated with or endorsed by Rockstar Games, Take-Two Interactive, Microsoft or Apple. Grand Theft Auto is a trademark of Take-Two Interactive. This repository contains no game files, keys or code from the game, and it never will. It only runs a copy that you own. D3DMetal is not included, and each user downloads it from Apple under Apple's terms.

The code is licensed under the [GNU General Public License v3.0](LICENSE).
