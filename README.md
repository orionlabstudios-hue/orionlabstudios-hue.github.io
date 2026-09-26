# Cloud Chase support site (prepared, not published)

Plain HTML/CSS for GitHub Pages (NEXT.md DROP 8 section 6). Nothing here is live.

- `index.html` - support page and contact email.
- `privacy.html` - the privacy policy, from `_OneShot_incoming/Legal/privacy-policy.md` without its "Before publishing" section. Keep the two in step.
- `delete-data.html` - how to delete Cloud Duel data in the game and by email.
- `app-ads.txt` - placeholder until the AdMob account exists.
- `.nojekyll` - tells GitHub Pages to serve the files as they are.

No pictures: DROP 10 rules out AI pictures; gameplay screenshots may be added later.

## To publish (King and Pep, once the domain is bought)

1. Put the contents of this folder at the root of the GitHub Pages branch or repository.
2. Add a file named `CNAME` containing only the domain (for example `cloudchase.example`), and point the domain's DNS at GitHub Pages as GitHub's instructions say.
3. Replace `orionlabstudios@gmail.com` with the studio's own support address everywhere in this folder and in the policy, if it changes.
4. Put the privacy URL (`https://<domain>/privacy.html`) into the game's `SettingsPanel` privacy-link constant and both store consoles.
