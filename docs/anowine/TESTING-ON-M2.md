# Testing AnoWine on your Mac

This is the first test build of AnoWine. It doesn't have the proxy yet. It checks two things:

1. The app installs and runs Steam and games like Whisky does.
2. The macOS sandbox that the proxy's kill switch will use doesn't break graphics. GitHub's machines can't test that.

It takes about 30–45 minutes, most of it waiting for downloads. Your Whisky install isn't touched: AnoWine is a separate app with its own bottles.

## 1. Download

1. Open the latest **AnoWine Test Build** run: <https://github.com/HighStormPVP/AnoWine/actions/workflows/AnoWineTestBuild.yml>.
2. At the bottom, under **Artifacts**, download **AnoWine-test**. You need to be signed in to GitHub.
3. Unzip it. You get `AnoWine-test.zip` and `m2-sandbox-check.sh`. Unzip `AnoWine-test.zip` too, to get **AnoWine.app**.
4. Drag **AnoWine.app** into your **Applications** folder.

## 2. First launch

AnoWine isn't notarized by Apple yet, so macOS blocks it the first time.

1. Double-click AnoWine. macOS says it can't be opened. Click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down. Next to the message about AnoWine, click **Open Anyway** and confirm with your password or Touch ID.
3. AnoWine opens and offers to install Rosetta (if needed) and the **Wine runtime** (about 330 MB). Let it.

## 3. Steam

1. Create a bottle, for example "Steam".
2. Install Steam from the launcher options in the bottle, the same way you would in Whisky.
3. Log in and install one game you know works under Whisky or CrossOver. Something light is best on an M2 Air.
4. Play it for a minute.

Things to note: anything that looks different from Whisky, and anything that still says "Whisky" in the interface.

## 4. Sandbox check

1. Quit Steam.
2. In AnoWine, select the Steam bottle and click **Open Terminal**.
3. In that Terminal window, type the following (adjust the path if you unzipped elsewhere) and press Return:

   ```
   bash ~/Downloads/AnoWine-test/m2-sandbox-check.sh
   ```

4. It starts Steam twice: once normally and once inside the sandbox. Each time, wait for Steam to load, open the Store page, and launch your game if you can. Then come back to Terminal, press Return, and answer the three questions.
5. At the end it prints a short block between two lines. Copy it and send it back.

The sandbox round still allows internet access. The only difference between the two rounds is the sandbox itself, which is what we're testing.

## What to send back

- The block from step 4.
- Anything odd from step 3, with screenshots if something looks wrong.
