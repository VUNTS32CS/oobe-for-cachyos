# OOBE for CachyOS

> [!WARNING]
> **fully personal system script — "Not For Public Use"**
>
> **do not run on your machine.** *All Rights Reserved*. this script is tailored specifically for my own hardware and CachyOS setup *(e.g., hard-blacklisting specific kernel modules and removing specific `linux-firmware` packages)*.

## about the script
this is a personal Out-Of-Box-Experience (OOBE) sorta' thing coded by both Devin Desktop *(~%25)* and Antigravity *(~%75)* specifically for my own CachyOS laptop and desktop setups. yes it **is** *vibe coded*, in ~5 hours.
### what it uses
it uses Gum `(gum)` for that modern TUI look while having Bash under the hood.
### some features
- **interactive questions**: each question defaults to `Yes` and includes a questions menu so you can jump between questions and see which ones are already `(Applied)` or `(Skipped)`.
- **safe countdowns**: applying a change triggers a 6-second countdown where pressing `Q` lets you change your mind on the question, `Enter` skips the timer and `Ctrl + C` stops the script.
