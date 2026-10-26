# ARK: Survival Evolved Optimizer

A small, free Windows tool that makes **ARK: Survival Evolved** (Steam) run smoother while keeping it looking as good as your PC allows.

It detects your hardware (CPU, GPU, VRAM, RAM) and builds an **auto-balanced** profile for your PC. You can also pick one of five fixed profiles, from "very weak PC" to "best visuals".

## Auto-balanced profile

ARK is mostly limited by the CPU, so on many PCs the graphics card sits idle part of the time. The auto-balanced profile sets every option based on which part it actually loads:

- **GPU settings** (textures, anti-aliasing, post-processing, effects, sky, resolution, texture sharpness) follow your **GPU**. If the GPU has power to spare, you get a nicer picture at no CPU cost.
- **Textures** follow your **VRAM**. They cost memory, not speed.
- **CPU settings** (view distance, grass, shadows) follow your **CPU**, so the game does not stutter.
- The recommended **FPS limit** and **creature count** are also based on your CPU. A frame rate your CPU can hold steadily gives even frame pacing and less wasted power.

This way the CPU and GPU are both used well and neither waits for the other.

## "Launch ARK" shortcut: self-repair + auto-tune

The optimizer creates a **Launch ARK** shortcut on your desktop. Start the game with it and it will:

1. **Check your settings.** ARK sometimes resets its config after an update or a crash. The launcher notices it and restores the optimized settings. If you changed something in the game menu on purpose, you can keep your version.
2. **Start ARK with high CPU priority**, so Windows gives the game priority over background programs.
3. **Auto-tune.** While you play, it measures how busy the graphics card and the busiest CPU core are (loading screens and menus are skipped). When you quit, it tells you what limited the game:
   - **GPU has spare power** → suggests a nicer picture (anti-aliasing, shading, effects, lighting, sky, resolution)
   - **GPU at its limit** → suggests lowering a few GPU settings for smoother play and a cooler card
   - **CPU is the limit** → asks if the game stuttered and, if so, lowers view distance, grass and shadows
   - **Well balanced** → no changes

   Nothing changes without your confirmation. Play at least 10 minutes for a result. Keep the launcher window open while playing (you can minimize it).

The launcher uses a copy of the optimizer and a small settings file in `%LOCALAPPDATA%\ARK_Optimizer`, which are deleted with option 2.

## What it does

**Game settings**
- Auto-balanced graphics profile for your CPU and GPU (or a fixed profile of your choice)
- Turns off effects that cost performance and make the picture worse or blurrier (motion blur, depth of field, chromatic aberration, lens flares)
- On good GPUs keeps ambient occlusion (depth) and water reflections ON, on weak GPUs turns them off for speed
- Shows exactly which quality levels were set, so you can check them in the game menu
- FPS limit (45 recommended / 60 / 30 / none) - the biggest power saver: the GPU uses less electricity, runs cooler and quieter, visuals stay the same
- True fullscreen mode, VSync off, faster level streaming
- Texture streaming pool sized to your VRAM (sharper textures, less pop-in)
- Single player: fewer wild creatures (70 % / 50 % / 100 %), the biggest CPU load in ARK
- Single player: corpses decay faster (fewer objects on the map)
- Weak graphics: recommends `-nomansky` (simpler sky); very weak / integrated graphics: also DirectX 10 mode (`-sm4 -d3d10`) for the biggest FPS gain

**Windows**
- Enables Game Mode
- Disables background game recording (Xbox Game Bar)
- Power plan: Balanced (recommended, less electricity) or High performance

**Clean-up (optional)**
- Deletes crash dumps and old log files (can take up GBs)
- Disables the intro videos so the game starts faster (moved to a backup folder, restored with option 2)
- Never touches your saves, settings or game data
- Creates a "Launch ARK" desktop shortcut (settings self-repair, high CPU priority, auto-tune - see below)
- Warns you if the game is installed on a slow hard drive (HDD)

**Faster map loading**
- Optional: excludes only the ARK folder from Windows Defender scanning, so Defender does not scan every game file while ARK loads tens of GB (asks for permission, undo with option 2)
- On a hard drive (HDD): offers to defragment it with the built-in Windows tool
- Warns if you have downloaded mods, since every mod makes loading longer
- Fewer wild creatures (see above) also makes creating a new world and loading a save faster

**DXVK (optional, experimental, single player only)**
- Downloads the official [DXVK](https://github.com/doitsujin/dxvk) release and puts `d3d11.dll` and `dxgi.dll` into `ShooterGame\Binaries\Win64`
- DXVK translates DirectX 11 to Vulkan. In CPU-heavy games like ARK it can raise FPS and reduce stutter, but results differ per PC
- Newer GPUs get DXVK 2.6.2, older GPUs get 1.10.3 (works with older Vulkan drivers)
- Downloaded only once: a local copy is kept in `%LOCALAPPDATA%\ARK_Optimizer`, and if DXVK is already installed, running the optimizer again keeps it without downloading anything
- Start the game **without BattlEye** when using it. Online servers with BattlEye may not allow it
- Remove it any time with option 3

**More loading and stutter fixes**
- Sets Windows to run ARK on the **high-performance graphics card** (laptops with two GPUs often run games on the weak one by mistake)
- Disables **fullscreen optimizations** for ARK (real exclusive fullscreen, less stutter for many players)
- Game on a hard drive: finds an **SSD in your PC with enough free space** and tells you exactly where to move ARK (reads the real game size from Steam)
- Game on a hard drive: turns the Windows **SysMain** service back on if it was disabled (it preloads files and speeds up HDD loading)
- Warns if the Windows **page file** is disabled or too small (a common cause of stutter and crashes in ARK)
- The launcher shows how much **free RAM** you have and which programs use the most, so you can close them before playing

**Built-in replacements for popular tools**
- **Upscale mode (like Magpie / FSR 1):** ARK renders at 85 % (Quality) or 75 % (Speed) resolution, which is much less work for the GPU, and your graphics driver sharpens the picture (Radeon Image Sharpening / NVIDIA Image Scaling). The program detects your GPU brand and shows exactly where to turn sharpening on. Recommended automatically for weak graphics.
- **Even frame pacing (like RTSS):** with DXVK installed, the FPS limit is done by DXVK (`dxvk.conf`), which delivers frames at even intervals. The in-game limit stays slightly higher as a backup.
- **Memory cleaner (like ISLC / RAMMap "Empty Standby List"):** optional. Before each start, "Launch ARK" empties the Windows standby memory so ARK gets more free RAM while loading the map. Windows asks for permission each time. Most useful on PCs with 8-12 GB RAM.

## External tools (optional, free unless noted)

The optimizer gets the most out of ARK's own settings and Windows, and already includes an even frame limiter (with DXVK) and a memory cleaner. These tools can add a bit more. Download them only from their official sites.

| Tool | What it does for ARK | Best for |
|---|---|---|
| **RTSS** (RivaTuner Statistics Server, from Guru3D, also comes with MSI Afterburner) | The most even frame limiter. Set "Framerate limit" to the same number as the optimizer (e.g. 45). Frames come at perfectly even intervals, so the game feels smoother with the same FPS. | Everyone, especially if the game feels "choppy" despite good FPS |
| **Magpie** (free, open source, GitHub) | Upscales the game: ARK renders at a lower resolution and Magpie sharpens it to full screen (FSR). | Weak / integrated graphics |
| **Lossless Scaling** (paid, Steam) | Upscaling plus frame generation: creates extra in-between frames, e.g. 30 FPS looks like 60. Adds a little input delay. | Weak graphics that cannot reach smooth FPS |
| **ISLC** (Intelligent Standby List Cleaner, Wagnardsoft) | Frees Windows standby memory. Can reduce stutter on PCs with 8-16 GB RAM, results differ per PC. | PCs with little RAM |

Magpie and Lossless Scaling need ARK in **Windowed Fullscreen** mode (game menu > Options). The optimizer sets real fullscreen, so change it in the game menu; when the launcher asks about changed settings, choose **2 = keep the current ones**.

**GPU driver settings:** keep **Shader Cache** turned on (AMD Adrenalin: Graphics > Advanced > Shader Cache "AMD optimized"; NVIDIA Control Panel: Shader Cache Size "Driver default" or larger). It stores compiled shaders, so the game stutters less when you return to places you have already seen.

**Hardware that helps most:** an SSD for loading (often the biggest single improvement in ARK) and 16 GB RAM (8 GB works, but stutters).

## How to use

1. Start ARK once, wait for the main menu and close it (this creates the settings folder).
2. Download `ARK_Optimizer.bat` and double-click it.
3. If Windows shows "Windows protected your PC", click **More info → Run anyway**. Windows shows this for every downloaded script.
4. Choose **1** and follow the prompts. Pressing Enter always picks the recommended option for your PC.
5. Add the launch options it shows to Steam: ARK → Properties → Launch Options.

## Undo

Run the program again and choose **2**. It restores your original config files from the first backup, the power plan and game recording settings, removes DXVK, the Defender exclusion, the desktop shortcut and the launcher files, restores the Windows graphics options for ARK, and brings back the intro videos.

Choose **3** to remove only DXVK.

Backups are stored in `ARK\ShooterGame\Saved\Config\WindowsNoEditor\Backup_<date>`.

## Safety

- Plain text script. Open it in Notepad to see exactly what it does.
- Does not modify any game files (.exe, .pak, .uasset, maps). It changes only the config files in `Saved\Config`, and the optional DXVK only adds two files next to the game, which are removed with option 3.
- Admin rights are only requested (Windows prompt) for the optional Defender exclusion and defragmentation. Everything else runs as a normal user.
- Internet is used only if you choose to install DXVK (official GitHub release).
- Steam "Verify integrity of game files" does not remove DXVK or the settings.
- Safe for online servers: creature and corpse settings only apply to single player / your own hosted game and are ignored by servers.

## Requirements

- Windows 10 or 11
- ARK: Survival Evolved on Steam (not Survival Ascended)
