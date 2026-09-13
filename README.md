# FSTM list watcher

Checks every 10 minutes whether these FSTM master's lists are online:

- [`principale_IASC.pdf`](https://www.fstm.ac.ma/formation_initiale/files/mst/concours_2026_2027/inscription/principale_IASC.pdf)
- [`principale_AISC_TempsAmenage.pdf`](https://www.fstm.ac.ma/formation_initiale/files/mst/concours_2026_2027/inscription/principale_AISC_TempsAmenage.pdf)

As soon as one of them is, the watcher:

1. downloads the PDF into `downloads\`,
2. sends a notification to your phone (through [ntfy](https://ntfy.sh)),
3. shows a Windows notification and a popup that stays until you click it,
4. stops checking that list, and keeps checking the others.

It runs in the background with Windows Task Scheduler. Nothing to install on the PC, no window, and it keeps working after a reboot.

## How it knows the list is out

Each check sends one lightweight `HEAD` request to each URL:

| Server answer | Meaning | What the script does |
|---|---|---|
| `404 Not Found` | Not published yet | Logs it, checks again in 10 minutes |
| `200 OK` | A file is there | Downloads it, checks it really is a PDF (the file starts with `%PDF-`), then alerts you |
| Anything else, or no network | Server or connection problem | Logs it, checks again in 10 minutes |

> **Why does my browser show `304 Not Modified` for a PDF that exists?** Your browser already has the file in its cache and asks "has it changed?". `304` means "no". The script never sends that question, so it always gets a real `200`.

## Requirements

- Windows 10 or 11. The scripts use the built-in Windows PowerShell 5.1 and Task Scheduler.
- The PC must be on, awake and logged in for the checks to run.
- For phone alerts: the free **ntfy** app for [Android or iPhone](https://docs.ntfy.sh/subscribe/phone/).

## Setup

Open PowerShell in this folder and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install-Watcher.ps1
```

The installer:

- creates `config.json` with a random, private ntfy topic,
- registers a scheduled task named `FSTM-IASC-Watcher` (first check in 1 minute, then every 10 minutes),
- prints the ntfy topic to subscribe to.

Then:

1. **Phone**: open the ntfy app, tap **+** and subscribe to the topic printed by the installer. It is also stored in `config.json`.
2. **Test the alerts** (phone, Windows notification and popup):

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Watch-Pdf.ps1 -TestNotification
   ```

3. **Test a full detection** with a list that is already online (SGE):

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Watch-Pdf.ps1 -Url "https://www.fstm.ac.ma/formation_initiale/files/mst/concours_2026_2027/inscription/principale_SGE.pdf"
   ```

   You should get all the alerts and find `downloads\principale_SGE.pdf`. This does not affect the lists you watch.

Installer options:

| Option | Effect |
|---|---|
| `-IntervalMinutes 5` | Changes the time between checks (default `10`) |
| `-NoVbsLauncher` | Use this if your company blocks Windows Script Host (see [Troubleshooting](#troubleshooting)) |

Running the installer again replaces the existing task, so you can use it to change settings.

> Always run the scripts with `powershell.exe` as shown above. Windows notifications do not work under `pwsh` (PowerShell 7).

## Check that it is running

```powershell
# Last run, result (0 = OK) and next run
Get-ScheduledTaskInfo -TaskName FSTM-IASC-Watcher | Select-Object LastRunTime, LastTaskResult, NextRunTime

# Last checks
Get-Content .\logs\watcher.log -Tail 10
```

Normal log lines while you wait:

```text
2026-09-13 17:20:01  principale_IASC.pdf not published yet (404).
2026-09-13 17:20:01  principale_AISC_TempsAmenage.pdf not published yet (404).
```

## Watch another list

Add its URL to `urls` in `config.json`, with a comma between URLs and none after the last one:

```json
{
  "urls": [
    "https://www.fstm.ac.ma/.../principale_IASC.pdf",
    "https://www.fstm.ac.ma/.../principale_AISC_TempsAmenage.pdf",
    "https://www.fstm.ac.ma/.../another_list.pdf"
  ],
  "ntfyTopic": "fstm-iasc-..."
}
```

The next check picks it up. No need to reinstall. To stop watching a list, remove its line.

## After a list is found

Each list is handled on its own. Once `downloads\<file>.pdf` exists, that URL is not checked any more and the other lists keep being checked. To watch a list again, delete its file. When you have all the lists, stop the scheduled task for good:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Uninstall-Watcher.ps1
```

## Files

| File | Role |
|---|---|
| `Watch-Pdf.ps1` | Does one check. The scheduled task runs it every 10 minutes |
| `Install-Watcher.ps1` | Creates `config.json` and the scheduled task |
| `Uninstall-Watcher.ps1` | Removes the scheduled task |
| `run-hidden.vbs` | Starts the check without a window flashing |
| `config.example.json` | Template for `config.json` (URLs to watch and ntfy topic) |
| `config.json` | Your settings. **Not committed** |
| `logs\`, `downloads\` | Created at runtime. **Not committed** |

## Push to GitHub or GitLab

1. Create an **empty** repository, without a README or `.gitignore`:
   - GitHub: <https://github.com/new>
   - GitLab: <https://gitlab.com/projects/new> → *Create blank project*, and untick *Initialize repository with a README*.
2. In this folder, run:

   ```powershell
   git init
   git add .
   git status          # config.json, logs/ and downloads/ must NOT be listed
   git commit -m "Add FSTM list watcher"
   git branch -M main
   git remote add origin <REPO_URL>
   git push -u origin main
   ```

   `<REPO_URL>` is the URL shown on the new repository page, for example
   `https://github.com/<username>/fstm-watcher.git` or `https://gitlab.com/<username>/fstm-watcher.git`.

`config.json` is listed in `.gitignore` because your ntfy topic works like a password: anyone who knows it can read and send notifications on it. The repository can be public or private.

### Install it on another PC

```powershell
git clone <REPO_URL>
cd fstm-watcher
powershell.exe -ExecutionPolicy Bypass -File .\Install-Watcher.ps1
```

This creates a new ntfy topic. To keep the one your phone already follows, copy your `config.json` into the folder before running the installer.

## Troubleshooting

| Problem | Fix |
|---|---|
| `Access is denied` when running the installer | Your company may restrict Task Scheduler. Retry from a PowerShell window opened with **Run as administrator**, or ask your IT team. |
| `logs\watcher.log` is still empty 10 minutes after installing | Windows Script Host is probably blocked. Reinstall with `-NoVbsLauncher`. |
| No Windows notification | Focus Assist (Do Not Disturb) hides notifications. The popup still appears and the phone alert still arrives. |
| Nothing arrives on the phone | Check that the topic in the app matches `ntfyTopic` in `config.json`, then run the `-TestNotification` command. |
| `Toast skipped: it needs Windows PowerShell 5.1` in the log | The script was started with `pwsh`. Use `powershell.exe` as shown above. |
| `config.json is not valid JSON` in the log | A quote or comma is missing or extra in `config.json`. Compare it with `config.example.json`. |

## Limitations

- Checks only run while the PC is on, awake and logged in. After sleep, a check runs as soon as the PC is back.
- It watches these exact URLs. If the faculty publishes a list under another file name, the watcher won't see it, so keep an eye on the website too.
