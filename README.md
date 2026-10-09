From the repository root and puente, install on Linux with:

	./xui11.sh.fixed.sh --yes-install --skip-apt-wait

`--yes-install` opts in to installing system packages. To install without that
step, use `./xui11.sh.fixed.sh --no-auto-install`.

The Linux auto-installer also installs the official Xenia Canary AppImage on
x86_64 and verifies its release SHA-256. Use `--skip-xenia` to omit it. Xenia
cannot launch Xbox 360 games directly from a regular PC DVD drive; select a
legally owned `.iso` or `.xex` dump from Games after it has been dumped using a
compatible method.

USE:
sudo sh -c 'printf "%s ALL=(root) NOPASSWD: %s, %s\n" "$USER" "$HOME/.xui/bin/xui_startup_and_dashboard.sh" "$HOME/.xui/bin/xui_start.sh" > /etc/sudoers.d/xui-dashboard-$USER'
sudo chmod 0440 /etc/sudoers.d/xui-dashboard-$USER
sudo visudo -cf /etc/sudoers.d/xui-dashboard-$USER
FOR SOLVING SUDO PROBLEMS


FOR WINDOWS:
Run from the repository root:

	Set-ExecutionPolicy -Scope Process Bypass -Force
	.\xui\win\xui11.ps1

To allow the installer to install Python packages:

	.\xui\win\xui11.ps1 -YesInstall
