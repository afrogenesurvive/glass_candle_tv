**DeepSeeksaid**:

Here is a step-by-step guide to building the setup you've described. The goal is to create a central hub where you pull in content from all your sources, strip out the algorithmic feeds, and read intentionally.

### 🏗️ Phase 1: Set Up the Foundation (FreshRSS & RSS-Bridge)

First, we need the two core applications running. The easiest way to do this is with Docker, which keeps them isolated and easy to manage.

1.  **Install Docker & Docker Compose**: If you don't have them, install them on your server (a VPS, Raspberry Pi, or even your local machine).
2.  **Create a Directory**: Make a folder for your new setup, e.g., `mkdir ~/rss-hub && cd ~/rss-hub`.
3.  **Create a `docker-compose.yml` File**: This file will define and run both services. Paste the following content into a file named `docker-compose.yml`:

    ```yaml
    version: "3"
    services:
      freshrss:
        image: freshrss/freshrss:latest
        container_name: freshrss
        restart: unless-stopped
        ports:
          - "8080:80"
        volumes:
          - freshrss_data:/var/www/FreshRSS/data
          - freshrss_extensions:/var/www/FreshRSS/extensions
        environment:
          - TZ=UTC # Change to your timezone

      rss-bridge:
        image: rssbridge/rss-bridge:latest
        container_name: rss-bridge
        restart: unless-stopped
        ports:
          - "3000:80"
        volumes:
          - ./rss-bridge-config:/config
        environment:
          - TZ=UTC

    volumes:
      freshrss_data:
      freshrss_extensions:
    ```

    _Note: This is a basic configuration based on standard Docker images [citation:1][citation:4]._

4.  **Start the Services**: Run `docker compose up -d` in your terminal. This will download the images and start both containers in the background.
5.  **Complete FreshRSS Setup**: Open your browser and go to `http://localhost:8080` (or your server's IP). You'll see the FreshRSS installation page. Follow the on-screen instructions to create your admin account and choose your database (SQLite is fine for most users).

### 🎬 Phase 2: Configure Media Sources (YouTube & Instagram)

Now we'll tackle the trickiest parts: YouTube and Instagram.

**YouTube (The Clean Way):**
You don't need to log in or use an API key. You will subscribe to individual channel RSS feeds.

1.  **Install Youlag Extension**: Download the latest release of the **Youlag** extension from its GitHub page. Unzip it and move the `xExtension-Youlag` folder into the `freshrss_extensions` volume on your host machine. The easiest way to find this volume's location is to run `docker volume inspect rss-hub_freshrss_extensions` [citation:22].
2.  **Enable the Extension**: In FreshRSS, go to **Settings → Extensions** and enable **Youlag**. This will give you a clean, YouTube-like interface without the recommendation sidebar [citation:22].
3.  **Find & Add Channel Feeds**: For any YouTube channel you want to follow, you need its unique RSS feed URL. You can find the channel ID using various online tools, or you can use the `YouTubeChannel2RssFeed` extension to simplify this [citation:32]. Once you have the feed URL (e.g., `https://www.youtube.com/feeds/videos.xml?channel_id=UC...`), add it as a new subscription in FreshRSS. Youlag will automatically apply its video-friendly layout to this feed.

**Instagram (The Burner Account Method):**
This is fragile but it's the only way to see your own feed.

1.  **Create a Burner Account**: **Do not** use your personal Instagram account. Create a new, separate account just for this purpose [citation:23].
2.  **Get Cookies**: Log into Instagram with the burner account. Open your browser's Developer Tools (F12), go to the **Application/Storage** tab, and find the **Cookies** for `instagram.com`. Copy the values for `sessionid` and `ds_user_id` [citation:23].
3.  **Configure RSS-Bridge**: Open your RSS-Bridge instance (`http://localhost:3000`). Find the **Instagram Bridge** and click its **⚙️ icon**. Paste the `sessionid` and `ds_user_id` into the configuration fields and save.
4.  **Generate a Feed**: Now, use the Instagram bridge to generate a feed for your burner account's home feed or specific users you want to follow. Subscribe to this generated URL in FreshRSS.

### 🔌 Phase 3: Connect Everything Else

RSS-Bridge is your tool for the rest. Go to your RSS-Bridge interface (`http://localhost:3000`) to generate feeds for these sources.

- **Hacker News**: Use the `HackerNewsBridge` or simply subscribe to `https://hnrss.org/frontpage`.
- **Lemmy**: Use the `LemmyBridge` or a dedicated tool like `DDOR` to get a daily digest of your favorite communities [citation:5].
- **Reddit (Selected Subs)**: Use the `RedditBridge` for specific subreddits. Be aware this can be flaky and may need the Tor user-agent workaround if you hit rate limits [citation:4].
- **Bear Blog**: The `BearBlogBridge` is designed exactly for this, as it's used as the example in the RSS-Bridge docs [citation:4].
- **GitHub Repos & Orgs**: Use the `GitHubBridge` or the `CSS Selector Bridge`. For a cleaner feed of your notifications, you could also self-host `github-notifications-rss` [citation:35].
- **Bluelight Forums**: There is no dedicated bridge. You will need to use the **CSS Selector Bridge** to manually scrape the forum. This involves using your browser's "Inspect Element" tool to find the HTML tags for thread titles and links, then entering those selectors into RSS-Bridge.
- **Classic Forums**: If they don't have a native RSS feed (many older ones do, look for an RSS icon), you'll use the same **CSS Selector Bridge** method as you would for Bluelight.

### 📂 Phase 4: Organize and Tame the Flow in FreshRSS

This is where you turn a raw list of feeds into a manageable system.

- **Create Categories**: In FreshRSS, create categories like "Forums," "Tech," "Social," "YouTube," etc., to group similar feeds together.
- **Use Mute & Hide**: This is crucial for breaking addictive patterns. **Mute** a feed to temporarily stop it from appearing in your main "All Articles" stream. **Hide** a feed to remove it entirely unless you click directly on that specific feed [citation:26]. Use this for high-volume or low-priority sources.
- **Set Up Filters**: You can create "Mark as Read" rules to automatically filter out noise. For example, a rule like `!(want OR need OR important)` in a feed's settings will mark everything _except_ articles containing those words as read, effectively hiding them [citation:37].
- **Discord Notifications**: If you want to be notified of specific articles in a Discord channel, install the **FreshRSS Webhook Extension**. You can configure it to send a message to a Discord webhook URL only when an article matches a specific filter (e.g., `intitle:breaking` or `#your-project-name`) [citation:33].

### 💡 What to Expect

This setup will give you a single, finite, chronological stream of information from all your chosen sources. You will lose the algorithmic "pull" of YouTube, Instagram, and Reddit, which is the primary goal. The trade-off is maintenance. Bridges for sites like Instagram and Reddit can break when the platforms change their code, and the CSS Selector Bridge for forums requires manual setup and upkeep. But the result is a personalized, non-addictive feed that you fully control.

---
