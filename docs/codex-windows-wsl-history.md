# Codex storage: Windows owns the conversations

The Windows app and native Windows CLI use the Windows user CODEX_HOME and
CODEX_SQLITE_HOME. Preserve the configured native profile and its absolute paths.
Agent environment is Windows native; the default integrated terminal is PowerShell.
WSL commands and WSL-hosted repositories can still be used explicitly.

Sessions and archived_sessions must be physical directories inside the native
Windows profile. Do not link either directory to the Linux CLI home or the former
Windows .codex profile. Configuration, authentication, databases, and transcripts
are no longer synchronized across Windows and WSL.

If the Linux CLI is explicitly used, its home and SQLite are private to Linux:
~/.codex and ~/.codex/sqlite. Its wrapper sets these paths explicitly, including
inside old shells that inherited a Windows CODEX_HOME. Retired sharing databases
are preserved separately; do not import their old shared rollout paths.

The historical sharing helper is retained for evidence and diagnostics, but its
migrate command is disabled. Back up before any storage changes; never overwrite
live transcripts or transplant old app settings into the active Windows profile.

Historical transcript text may still mention Linux paths. These are historical
records, not an instruction to switch the current agent into WSL. Workspace paths
for native tasks may use Windows drive paths or explicit WSL UNC paths.
