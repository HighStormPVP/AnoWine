# Testing Ano on your Mac

This test build of Ano has the first part of the proxy: TCP and name lookups go through your proxy client. UDP is blocked and there's no kill switch yet. The test checks three things:

1. The app installs and runs Steam and games like Whisky does.
2. Steam works through your proxy client.
3. The macOS sandbox that the proxy's kill switch will use doesn't break graphics. GitHub's machines can't test that.

It takes about 30–45 minutes, most of it waiting for downloads. Your Whisky install isn't touched: Ano is a separate app with its own bottles.

## 1. Download

1. Open the latest **Ano Test Build** run: <https://github.com/HighStormPVP/AnoWine/actions/workflows/AnoWineTestBuild.yml>.
2. At the bottom, under **Artifacts**, download **Ano-test**. You need to be signed in to GitHub.
3. Unzip it. You get `Ano-test.zip` and `m2-sandbox-check.sh`. Unzip `Ano-test.zip` too, to get **Ano.app**.
4. Drag **Ano.app** into your **Applications** folder.

## 2. First launch

Ano isn't notarized by Apple yet, so macOS blocks it the first time.

1. Double-click Ano. macOS says it can't be opened. Click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down. Next to the message about Ano, click **Open Anyway** and confirm with your password or Touch ID.
3. Ano opens and offers to install Rosetta (if needed) and the **Wine runtime** (about 480 MB). Let it.

## 3. Steam

1. Create a bottle, for example "Steam".
2. Install Steam from the launcher options in the bottle, the same way you would in Whisky.
3. Log in and install one game you know works under Whisky or CrossOver. Something light is best on an M2 Air.
4. Play it for a minute.

Things to note: anything that looks different from Whisky, and anything that still says "Whisky" in the interface.

## 4. Proxy

1. Make sure your proxy client (Hiddify) is running.
2. In Ano, open **Settings → Proxies** and click **Add Proxy…**. The form is already filled in for Hiddify: SOCKS5, `127.0.0.1`, port `1080`. Save it.
3. Click **Test**. It should show an exit IP address that isn't your own.
4. Quit Steam. Select the Steam bottle, open **Network**, and choose the proxy.
5. Start Steam again. Log in, open the Store page, and start a download.

Things to note: whether Steam logs in and downloads, anything that doesn't load, and what the **Network** section shows (port, open connections, last error). Voice chat and some multiplayer games won't work yet, because UDP is blocked.

To check that nothing leaks, quit your proxy client while Steam is open. Steam should lose its connection, not carry on.

## 5. Sandbox check

1. Quit Steam.
2. In Ano, select the Steam bottle and click **Open Terminal**.
3. In that Terminal window, type the following (adjust the path if you unzipped elsewhere) and press Return:

   ```
   bash ~/Downloads/Ano-test/m2-sandbox-check.sh
   ```

4. It starts Steam twice: once normally and once inside the sandbox. Each time, wait for Steam to load, open the Store page, and launch your game if you can. Then come back to Terminal, press Return, and answer the three questions.
5. At the end it prints a short block between two lines. Copy it and send it back.

The sandbox round still allows internet access. The only difference between the two rounds is the sandbox itself, which is what we're testing. You can run this from a proxied bottle: both rounds then go through the proxy. Keep Ano open while you do: the Terminal window uses the app's proxy helper.

## What to send back

- The block from step 5.
- What happened in step 4 (proxy).
- Anything odd from step 3, with screenshots if something looks wrong.

## Ano-8: runtime 4.9.0

Ano-8 moves to runtime 4.9.0: Wine 11.19 with CrossOver's Mac patches, from upstream
Whisky's engine 4.8.3, with Ano's names. Report each item as pass or fail.

**Before you start, copy your Steam bottle.** Opening a bottle with 4.9.0 updates it, and
Ano-7 cannot undo that. Right-click the Steam bottle in Ano-7 and choose **Duplicate
Bottle...** (it copies the installed games too, so check your free space). Leave the copy
unopened in Ano-8.

**To go back to Ano-7:** quit Ano, delete the folder
`~/Library/Application Support/io.github.highstormpvp.Ano/Libraries` (that is the runtime;
Ano-7 downloads 3.1.6 again), install Ano-7 with its install line, and use the copy.

1. Open Ano-8. It offers runtime 4.9.0; accept it. **Settings** then shows 4.9.0.
2. Open your existing Steam bottle (proxy on, Hiddify running). Steam starts, signs in,
   and the store, menus and popups draw.
3. Start a game download. It runs, and Hiddify shows Steam's connections.
4. Start a game from Ano's **Library**. The tile shows it running, and closing the game
   clears that.
5. Optional (D3DMetal): download Apple's Game Porting Toolkit (it needs an Apple developer
   sign-in), import it in **Settings**, set a DirectX 12 game's graphics to D3DMetal, and
   start it.
6. Still open from before: run `m2-sandbox-check.sh` (section 5).
7. Start-up time: with Steam running in the Steam bottle, click **Open Terminal** for that
   bottle and run `time ano-loader cmd /c echo hi` three times. Send the three `real`
   times. On GitHub's test Macs each one takes about 8 seconds on this runtime while
   another program runs in the bottle (about 1 second on 3.1.6).
8. Create a new bottle. It finishes without an error. Note roughly how long it takes.
9. In that new bottle, open **Winetricks** and install `d3dcompiler_47`. It finishes
   without an error. Note roughly how long it takes.

## D3DMetal names (only if you have imported the Game Porting Toolkit)

The rename (Plan 3c) has to keep the few Wine names that Apple's D3DMetal looks for, because
Apple's files cannot be changed. This lists them. It only reads files; it changes nothing.

1. Download `list-gptk-wine-names.sh` from the
   [ano-test-8 release](https://github.com/HighStormPVP/AnoWine/releases/tag/ano-test-8).
2. In Terminal: `bash ~/Downloads/list-gptk-wine-names.sh`
3. Send back `ano-gptk-wine-names.txt` from your Desktop.

If it says no Game Porting Toolkit has been imported, skip this section: it needs item 5 of
the Ano-8 list first.

## Ano 9: runtime 5.0.0

Ano 9 runs on runtime 5.0.0. It is the same engine as 4.9.0, built by Ano and renamed so
that nothing in it says "wine". Bottles made by Ano 6–8 can't be used with it, so you make
new ones. Report each item as pass or fail, with what it asks you to send.

**To go back to Ano 8:**
1. Quit Ano.
2. Delete the folder `~/Library/Application Support/io.github.highstormpvp.Ano/Libraries`.
3. Install Ano 8 with its install line. It downloads 4.9.0 again.
4. Import the Game Porting Toolkit again in **Settings**: Ano 9 renamed its copy.

Your old bottles still work in Ano 8, because Ano 9 never changes them. Bottles you made in
Ano 9 stay in Ano 8's list but won't work there; remove them from the list. If you had turned
off **Automatically check for Ano runtime updates**, turn it off again in Ano 8.

1. **Install.** Install Ano 9 and open it. It offers runtime 5.0.0; accept. Send how long
   the download and setup took. To see the version once you have a bottle (item 3): open
   the bottle's configuration, and under **Stability** click **Generate Stability
   Diagnostics**. The report says `Ano runtime version: 5.0.0`.
2. **Old bottles.** Your Ano 8 bottles are still in the list, marked **Made with an earlier
   Ano**. Clicking one shows "can't be used with this one" instead of opening it.
   Before you start, note the Steam bottle folder's **Date Modified** in Finder; it is the
   same afterwards.
3. **Steam in a new bottle.** Create a new bottle, install Steam in it, sign in, and open
   the store. Download a game and start it from Ano's **Library**. Watch for Steam or a
   game's anti-cheat saying it doesn't support this system: they can look for Wine by
   name, and the rename may change their answer. Send a screenshot of any such message.
4. **D3DMetal** (if you imported the Game Porting Toolkit in Ano 8). Don't import it again.
   Set a DirectX 12 game's graphics to D3DMetal and start it. It should start without a new
   import, because Ano 9 carries the toolkit over. This item also tells us whether D3DMetal
   still finds the two settings it reads by their old names. If the game fails here but
   starts with **DXVK**, say so.
5. **DXVK.** Start a game with graphics set to DXVK, a 32-bit game if you have one: 32-bit
   DXVK crashes on GitHub's test Macs, so we can't check it there.
6. **Proxy.** With Hiddify running, turn the proxy on for the Steam bottle. Steam signs in
   and Hiddify shows its connections (the limits from Ano-6 still apply: no UDP yet).
7. **Update setting.** If you turned off **Automatically check for Ano runtime updates** in
   Ano 8 (**Settings**, **Updates**), it is still off in Ano 9.
8. **Rosetta's cache.** Run `clean-rosetta-cache.sh` as in "Ano 9: clean old traces" below,
   first without and then with `--delete`, and send both last lines.
9. **No "wine" left.** With a game running, open Activity Monitor and search for `wine`:
   nothing shows. In Terminal, `ps ax | grep -i wine` shows only its own `grep` line.
   `ls ~/.cache/winetricks` says "No such file or directory" (unless you have Homebrew's
   winetricks or the original Whisky installed, which share that folder).
10. **D3DMetal names.** If you haven't sent `ano-gptk-wine-names.txt` yet, see "D3DMetal
    names" above; the script is attached to the ano-test-9 release too.

## Ano 9: clean old traces

On its first launch Ano 9 removes what Ano 6–8 left with the old runtime's names. One trace
it can't remove itself: Rosetta keeps a translated copy of every Intel program file it has
run in `/var/db/oah`, and the copies of the old runtime's files still have the old names
(for example `winemac.so.aot`). That folder belongs to macOS, and only an administrator can
read or change it, so the script needs `sudo` (it asks for your Mac password).

Removing them is safe: Rosetta makes the copies again for any program that still needs
them. The same files of other apps such as Whisky or CrossOver go too; their next start may
take a little longer while Rosetta remakes them.

1. Download `clean-rosetta-cache.sh`. It is attached to the ano-test release; download it
   from the [release page](https://github.com/HighStormPVP/AnoWine/releases) in your browser.
2. Look first. In Terminal (it lists the files and how many there are, and changes nothing):

   ```
   sudo bash ~/Downloads/clean-rosetta-cache.sh
   ```

3. Then delete them:

   ```
   sudo bash ~/Downloads/clean-rosetta-cache.sh --delete
   ```

4. Send back the last line of each run. If it says "nothing to clean", there was nothing left.

## Ano 9: runtime 5.0.1

Do this once I tell you 5.0.1 is published. That happens after you send the "Ano 9: runtime 5.0.0"
results. Runtime 5.0.1 is 5.0.0 with the last three ways a Windows program could find "wine"
removed:
- the copyright line in every Windows file the engine ships;
- six old function names;
- two D3DMetal settings that every program could see.

Your Ano 9 bottles keep working. The first start of each bottle takes a little longer while the
engine refreshes its Windows files. Report each item as pass or fail.

1. **Update.** Open Ano 9. It says "You are running Ano runtime 5.0.0, but 5.0.1 is available";
   click **Update**. If you turned off **Automatically check for Ano runtime updates**
   (**Settings**, **Updates**), turn it on, reopen Ano, and turn it off again afterwards. Then
   in the Steam bottle, **Generate Stability Diagnostics** says `Ano runtime version: 5.0.1`.
2. **Steam in your Ano 9 bottle.** Open the Steam bottle you made on 5.0.0. Steam starts already
   signed in, and a game starts from Ano's **Library**. Send how long the bottle's first start
   took.
3. **D3DMetal.** This item matters most. Start the DirectX 12 game from "Ano 9: runtime 5.0.0"
   item 4 with graphics set to D3DMetal. 5.0.1 changes how D3DMetal finds the engine's functions,
   and only Apple's real files can show that it works. If the game fails:
   - say whether it started on 5.0.0;
   - send a screenshot of any message;
   - send the newest log from **File**, **Open Logs Folder**.
4. **DXVK.** Start a game with graphics set to DXVK.
