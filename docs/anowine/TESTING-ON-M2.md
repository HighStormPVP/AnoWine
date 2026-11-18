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
7. Start-up time: in Ano, select the Steam bottle, click **Open Terminal**, and run
   `time ano-loader cmd /c echo hi` three times. Send the three `real` times. On GitHub's
   test Macs each one takes about 8 seconds on this runtime (about 1 second on 3.1.6).
