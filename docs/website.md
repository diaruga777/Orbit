# Orbit website

The landing page is plain HTML, CSS, JavaScript and SVG in `website/`. No package
manager, third-party scripts, build service, API key or hosted backend is needed.
Its app UI is an interactive illustration with fictional projects, not a capture
of a physical install. It supports system appearance, a saved appearance override,
keyboard-operated preview tabs, native FAQ disclosures and reduced motion.

## Preview

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory website
```

Open `http://127.0.0.1:8765/`. Assets are relative, so the same files work under
GitHub Pages' repository path. To check that path locally, create a temporary
preview root containing an `Orbit` symlink to the absolute `website/` directory,
then serve that root and open `/Orbit/`.

## Free GitHub hosting

This public repository can use GitHub Pages on GitHub Free. Its project URL is
`https://diaruga777.github.io/Orbit/` (the repository name controls the path).
The source stays at `https://github.com/diaruga777/Orbit`.

1. Push the landing-page commit on `main` to GitHub.
2. In the repository's **Settings → Pages → Build and deployment**, choose
   **GitHub Actions** as the source. This is a one-time repository setting.
3. Run **Actions → Deploy landing page → Run workflow** if the initial push ran
   before Pages was enabled. Later changes to `website/` on `main` deploy
   automatically.
4. Check the workflow's deployment URL and open it before announcing the site.

The workflow grants deployment permission only to its deployment job and uploads
only `website/`, not the source checkout, local configuration or build outputs.
It does not create releases or upload DMGs.

GitHub lists a 1 GB published-site limit and a soft 100 GB/month Pages bandwidth
limit. An open source project landing page fits this use; commercial transaction
sites and commercial SaaS have separate restrictions. Check the current
[Pages limits](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)
before changing the site's purpose.

## DMG downloads

Use **GitHub Releases** for the DMG, alongside the source repository. Each asset
must be under 2 GiB. GitHub currently lists no total release-size or release
bandwidth limit. See
[About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
Keep DMGs out of Git history and the Pages artifact.

There is currently no public DMG. The page says so and links to the Releases
listing and source-build instructions. Before offering a public download,
complete physical acceptance and the Developer ID/notarization process in
[distribution](distribution.md). A development review DMG does not qualify.

After that, create a release from the verified tag and attach
`Orbit-release.dmg` and its SHA-256 file. Use the same asset filename for each
public release. Update the download section in `website/index.html`:

- Change **Check releases** to **Download for Mac**.
- Point it to
  `https://github.com/diaruga777/Orbit/releases/latest/download/Orbit-release.dmg`.
- Replace the **No public DMG yet** note with the real version, architecture and
  requirements. Current packaging is build-host architecture, not universal.
- Keep a link to the release notes and checksum. Verify the download after
  deployment. Do not imply notarization or physical acceptance from a build.

This approach keeps the website, source and DMG on GitHub without a domain or
separate hosting subscription. GitHub's current quotas and terms still apply.
