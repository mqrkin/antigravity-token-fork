Use README.md in this repository as the authoritative installation guide. It describes the Windows and Linux or WSL2 release archives, prerequisites, sign-in, CLI environment variables, and verification.

Check for existing Antigravity Tools and agy installations before making changes. The installers modify user configuration and background startup; Windows stops existing Tools and gateway processes, while Linux restarts the two user services. Preserve existing accounts. Do not use the optional account-reset flags without the computer owner's explicit request.

Use the release archive for the target operating system. The Linux installer requires the packaged runtime, which is not present in a plain Git checkout. The Windows installer starts Google sign-in and waits for the callback. On Linux run the installed login.py with --wait. Only the owner should authenticate their Google account; never ask them to disclose credentials or OAuth callback URLs in chat.

The gateway responds to an unauthenticated health check at http://127.0.0.1:5919/health. A successful health check proves only that the gateway process is running. Verify the authenticated CLI path separately and report whether the upstream model and account were actually tested.

This fork supplies a fixed low-severity response to the CLI safety-rater request instead of sending that request to an upstream safety model. Ensure the owner understands this behavior before installing.
