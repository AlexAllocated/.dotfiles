# tmux cheat sheet

tmux keeps shells and programs alive independently of the terminal window.

```text
server
└── session        a workspace that survives terminal disconnects
    ├── window     roughly a durable terminal tab
    │   └── pane   a split inside that window
    └── window
```

## Prefix notation

Almost every tmux shortcut starts with the prefix: press `Ctrl+B`, release it,
then press the listed key. `C-b ?` opens tmux's complete live key reference;
press `q` to close it.

## Starting and returning

| Goal                                  | Command or key        |
| ------------------------------------- | --------------------- |
| Create or attach to the usual session | `tmux new -As main`   |
| List sessions                         | `tmux ls`             |
| Attach later                          | `tmux attach -t main` |
| Detach safely                         | `C-b d`               |
| Choose a session                      | `C-b s`               |
| Rename the current session            | `C-b $`               |
| Send a literal prefix to nested tmux  | `C-b C-b`             |

Detach before closing the GUI when practical. Closing a terminal normally
detaches it too, but `C-b d` makes the intention explicit.

## Windows (durable tabs)

| Goal                            | Key               |
| ------------------------------- | ----------------- |
| New window                      | `C-b c`           |
| Next / previous window          | `C-b n` / `C-b p` |
| Previously used window          | `C-b l`           |
| Select window 0–9               | `C-b 0` … `C-b 9` |
| Interactive window chooser      | `C-b w`           |
| Rename window                   | `C-b ,`           |
| Close window, with confirmation | `C-b &`           |

## Panes (splits)

| Goal                               | Key                      |
| ---------------------------------- | ------------------------ |
| Split left/right                   | `C-b %`                  |
| Split top/bottom                   | `C-b "`                  |
| Focus a neighboring pane           | `C-b Arrow`              |
| Cycle through panes                | `C-b o`                  |
| Return to the last pane            | `C-b ;`                  |
| Show pane numbers, then choose one | `C-b q`, then its number |
| Toggle pane fullscreen/zoom        | `C-b z`                  |
| Swap pane backward/forward         | `C-b {` / `C-b }`        |
| Cycle layouts                      | `C-b Space`              |
| Close pane, with confirmation      | `C-b x`                  |

Resize by one cell with `C-b Ctrl+Arrow`, or five cells with
`C-b Alt+Arrow`. The arrow binding repeats briefly without pressing the prefix
again.

## Scrolling and copying

Mouse support is enabled. The wheel enters tmux copy mode automatically, and a
mouse drag selects and copies through the terminal clipboard. Press `q` or
`Escape` to return to the live pane.

| Goal                        | Key                          |
| --------------------------- | ---------------------------- |
| Enter copy mode             | `C-b [`                      |
| Enter copy mode one page up | `C-b PageUp`                 |
| Move                        | Arrows, `PageUp`, `PageDown` |
| Begin keyboard selection    | `Ctrl+Space`                 |
| Copy selection and exit     | `Alt+W`                      |
| Search backward / forward   | `Ctrl+R` / `Ctrl+S`          |
| Exit copy mode              | `q`, `Escape`, or `Ctrl+C`   |

In most GUI terminals, holding `Shift` while selecting bypasses tmux and uses
the terminal emulator's own selection instead.

## Useful recovery facts

- `C-b :` opens tmux's command prompt.
- `tmux source-file ~/.config/tmux/tmux.conf` reloads this configuration.
- `exit` or `Ctrl+D` ends the shell in the current pane. The last pane ends its
  window; the last window ends the session.
- `tmux kill-session -t main` deliberately terminates the entire named session.
- tmux survives terminal, browser, SSH, and Sunshine disconnects, but it does
  **not** survive a reboot. Automatic reboot restoration is not enabled.
