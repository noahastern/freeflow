---
name: install
description: Build the latest origin/main of this FreeFlow fork and install it into /Applications. Use when the user asks to install, rebuild, reinstall, or update their own FreeFlow app, or says yes to an install offer after a change lands on main.
---

# Install FreeFlow from origin/main

1. Run `git fetch origin main` and compare it with the local branch. If there are local commits not on `origin/main`, or uncommitted changes, tell the user they will not be in the build, and ask whether to push first. Do not push without their OK.
2. Run `make install` from the repository root in the background (the build takes a couple of minutes). It quits FreeFlow, replaces `/Applications/FreeFlow.app`, and relaunches it.
3. Report the commit that was built (the "Building origin/main at ..." line) and the installed version, or the error output if it failed.

If it fails with "No Apple Development signing identity found", the user needs an Apple Development certificate in their keychain; do not change signing settings yourself.
