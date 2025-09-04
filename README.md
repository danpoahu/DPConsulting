# DPConsulting — Legal & Support Pages

This repo hosts public pages for the **Discover More** app: Privacy Policy, Terms of Use, and Support.

## Files
- `privacy.html` — Privacy Policy
- `terms.html` — Terms of Use
- `support.html` — Support page (contact + deletion instructions)
- `index.html` — Landing page linking to the above

## Quick start (GitHub Pages)
1. Create a **public** GitHub repository (e.g., `dpconsulting-legal`).
2. Add these files to the repo and commit to the `main` branch.
3. Go to **Settings → Pages**:
   - Source: **Deploy from a branch**
   - Branch: **main** (/**root**)
4. Your site will appear at `https://<your-username>.github.io/<repo>/`.
5. Use the direct URLs in App Store Connect, e.g.:
   - Privacy Policy URL: `https://<username>.github.io/<repo>/privacy.html`
   - Support URL: `https://<username>.github.io/<repo>/support.html`

## Optional: Custom domain
- Add a DNS CNAME for e.g. `legal.<yourdomain>.com` pointing to `<your-username>.github.io`.
- In **Settings → Pages**, set the **Custom domain** and follow HTTPS instructions.
- Add a `CNAME` file at the repo root containing only your custom domain (e.g., `legal.example.com`).

## Keep the docs current
- Update the **Effective date** when you materially change the Privacy Policy or Terms.
- Replace the placeholder postal address with your real mailing address.
- If you add SDKs or new data types, update both the pages and your App Store Privacy answers.

Contact: info@discovermore.app
