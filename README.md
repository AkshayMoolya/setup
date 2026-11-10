# CloudLCMS — new laptop setup

One script installs everything a blank machine needs to run CloudLCMS locally.
You only need **this `setup/` folder** on the new laptop. Nothing else has to be there first.

Setup happens in two runs:

1. **Machine.** Copy `setup/` anywhere (Desktop, USB, Downloads) and run it. It installs
   every tool, database and library, plus Docker and Claude Code. Without the code
   present, it skips the app-specific steps and prints how to finish.
2. **App.** Clone the repos with git, then run the script again from the checkout.
   Tools installed in run 1 are skipped, so this run only installs the app's npm
   packages, writes `conf/config.json`, builds the frontend and runs `install.js`.

The script never clones anything itself. Re-running it is always safe, because each
step checks what is already there and skips it.

| File | Purpose |
| --- | --- |
| `setup.sh` | The setup script (Windows Git Bash, macOS, Ubuntu/Debian). |
| `bootstrap-windows.ps1` | Windows only. Installs Git (which provides bash), then runs `setup.sh`. |
| `requirements.txt` | Pinned Python libraries. Only used when `../doctocourse/requirement.txt` is missing. |
| `.gitattributes` | Keeps `setup.sh` on LF line endings so bash can run it on Windows. |

## What gets installed

| Area | What | Why the app needs it |
| --- | --- | --- |
| Source control | Git, GitHub CLI (`gh`) | Working with the repos. `install.js` also clones the Adapt framework. |
| Node | Node.js 22 + `grunt-cli`, `pm2`, `nodemon`, `adapt-cli` (global) | Server, frontend build, process manager, Adapt plugins. |
| Node packages | `npm install` in the app, `plugins/auth/{local,google,saml}`, `../doctocourse` | App dependencies. |
| Python | Python 3.11 + a virtualenv at `~/.venvs/cloudlcms` with `docling`, `python-pptx`, `beautifulsoup4`, `pillow` | PowerPoint import/export, PDF import. |
| Database | MongoDB 8.0 (+ `mongosh`) | Main database. |
| Search | Redis (Memurai Developer on Windows) | Course search index. |
| Documents | pandoc, LibreOffice, ImageMagick, Ghostscript, Poppler, ffmpeg | Word conversion, PPT→PDF→PNG slide rendering, media. |
| Containers | Docker (Docker Desktop on Windows/macOS, Docker Engine + Compose on Linux) | Building and running the `Dockerfile*` images. |
| AI | Claude Code (`claude`) | AI coding assistant in the repo. |

In run 2, once it can see the app checkout, the script also does the following:

- creates `conf/config.json` if it doesn't exist (local MongoDB, port 9080, dev mode, a random session secret, `PYTHON_VAR` pointing at the virtualenv);
- runs `grunt build:dev`;
- offers to run `node install.js`, which creates the database, the master tenant and the super-admin user, and downloads the Adapt framework.

## Before you start

- Use an account with admin rights. Installers ask for elevation (UAC on Windows, `sudo` on macOS/Linux).
- Expect run 1 to take 20–40 minutes, mostly downloading. `docling` pulls in PyTorch, which is about 1–2 GB.

## Run 1 — set up the machine (only this folder needed)

Copy the `setup/` folder onto the laptop, for example to the Desktop.

### Windows 10/11

A fresh Windows machine has no bash, so start from **PowerShell**:

```powershell
cd $HOME\Desktop\setup
powershell -ExecutionPolicy Bypass -File .\bootstrap-windows.ps1
```

The bootstrap installs Git for Windows, then runs `setup.sh` with Git Bash. Click **Yes**
on each admin prompt. Most packages come from `winget`; Ghostscript comes from its official
GitHub release, since it isn't on `winget`.

### macOS (Intel or Apple Silicon)

```bash
cd ~/Desktop/setup
bash setup.sh
```

macOS will offer to install the Xcode Command Line Tools (which include git); accept, and
the script waits for them. Homebrew is installed next and asks for your Mac password.

### Ubuntu 22.04 / 24.04, Debian 12, or WSL2

```bash
cd ~/Desktop/setup
bash setup.sh
```

When run 1 ends, it prints the clone commands for run 2.

## Get the code

Open a **new terminal**, so the freshly installed `git` and `gh` are on PATH. Then clone
both repos **side by side** into one folder. The app loads doctocourse with
`require('../../../../../doctocourse')`, so it must be a sibling:

```bash
mkdir -p ~/dev/cloudlcms && cd ~/dev/cloudlcms
gh auth login        # once; the repos are private (opens a browser)
git clone https://github.com/SRRInternational/adapt_authoring.git cloudlcms-2025
git clone https://github.com/SRRInternational/doctocourse.git
```

```
~/dev/cloudlcms/
├── cloudlcms-2025/   ← the app (its own copy of setup/ is inside)
└── doctocourse/      ← PowerPoint / Word import + export
```

On macOS, keep this folder out of `~/Documents` and `~/Desktop` when iCloud sync is on
(see `tools/mac-boot-check.sh` in the app).

## Run 2 — set up the app

Use either the copy of `setup/` inside the clone or your original copy. Both do the same thing:

```bash
bash ~/dev/cloudlcms/cloudlcms-2025/setup/setup.sh
# or
bash ~/Desktop/setup/setup.sh --app-dir ~/dev/cloudlcms/cloudlcms-2025
```

On Windows, run this in **Git Bash**, or again through `bootstrap-windows.ps1` (it passes
`--app-dir` and every other option through).

If `doctocourse` isn't next to the app, run 2 still finishes, but PowerPoint and Word
import/export won't work until you add it and re-run.

## When run 2 finishes

1. **Open a new terminal**, so PATH changes take effect everywhere.
2. On Windows and macOS, **start Docker Desktop once** and accept its terms. On Windows, reboot first if the script said WSL was just enabled.
3. Start the app:

   ```bash
   cd ~/dev/cloudlcms/cloudlcms-2025
   node server.js         # or: npm run debug   (nodemon + inspector on 9229)
   ```

4. Open <http://localhost:9080> and sign in with the super-admin account you created during `install.js`.

## Options

```
bash setup/setup.sh --verify            # check only; changes nothing
bash setup/setup.sh --app-dir PATH      # the app checkout to set up (default: the folder setup/ is in)
bash setup/setup.sh --skip-system       # skip OS packages (already have them)
bash setup/setup.sh --skip-docker       # don't install Docker
bash setup/setup.sh --skip-claude       # don't install Claude Code
bash setup/setup.sh --skip-build        # don't run grunt build:dev
bash setup/setup.sh --skip-app-install  # don't run node install.js
bash setup/setup.sh -y                  # no questions; take the defaults
```

To put the Python virtualenv somewhere else, set `CLOUDLCMS_VENV=/some/path`.

`--verify` prints a ✓/✗ line for every tool, service and build output. Run it any time something seems missing.

## About `install.js`

The script asks before running it, and skips it when `conf/config.json` already has a
`masterTenantID` (meaning it ran before). During the run:

- when asked **"use the values in config.json?"**, answer **Y**;
- enter the super-admin email and password when prompted.

To run it later yourself: `cd cloudlcms-2025 && node install.js`. In Git Bash's own
(mintty) window, use `winpty node install.js` so the password prompt works.

## Things you may need to do by hand

| Item | Where |
| --- | --- |
| Email (SMTP) | `useSmtp`, `smtpService`, `smtpUsername`, `smtpPassword`, `fromAddress` in `conf/config.json` |
| AI / PDF course generation (Gemini) | `API_KEY`, `MODEL_NAME` in `plugins/output/adapt/pdf/scripts/configAPI.json` (an empty file is created on first boot) |
| Copying an existing config from another machine | Copy `conf/config.json`, then fix `root` and `PYTHON_VAR` for this laptop. The script warns when `PYTHON_VAR` doesn't point at the virtualenv. |
| Production-style bundle | `npx grunt build:prod`. This **rewrites** `conf/config.json` (`isProduction: true`). |

Note that `*.json` is gitignored, so `conf/config.json` and `configAPI.json` are never committed.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `$'\r': command not found` | `setup.sh` has CRLF line endings. Run `git add --renormalize setup && git checkout -- setup`, or `sed -i 's/\r$//' setup/setup.sh`. |
| Server stops after about 10 s with a MongoDB timeout | MongoDB isn't running. **Windows:** `net start MongoDB` (admin), or run `"C:\Program Files\MongoDB\Server\8.0\bin\mongod.exe" --dbpath C:\data\db`. **macOS:** `brew services start mongodb-community@8.0`. **Linux:** `sudo systemctl start mongod`. |
| Search does nothing | Redis isn't running. **Windows:** start the *Memurai* service. Note that Memurai Developer edition stops after 10 days of uptime, so restart it then. **macOS:** `brew services start redis`. **Linux:** `sudo systemctl start redis-server`. |
| PowerPoint slides fail to render | `soffice`/`magick` (Windows) or `libreoffice`/`convert` (Linux/macOS) aren't on PATH. Open a new terminal; on Linux, check the ImageMagick PDF policy in `/etc/ImageMagick-6/policy.xml`. |
| `Python variable "…" is not valid` | `PYTHON_VAR` in `conf/config.json` must be the venv's Python: `~/.venvs/cloudlcms/Scripts/python.exe` (Windows) or `~/.venvs/cloudlcms/bin/python`. |
| A tool installed but is "not found" | Open a new terminal; installers only update PATH for new shells. |
| `docker` works but `docker info` fails | Start Docker Desktop (Windows/macOS). On Linux, log out and back in after being added to the `docker` group. |
| A step failed halfway | Fix the cause shown in red, then re-run `bash setup/setup.sh`. Completed steps are skipped. |
