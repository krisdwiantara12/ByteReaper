# DESIGN.md - ByteReaper (iOS Storage Cleaner)

## 1. Design Read
Reading this as: native iOS storage inspection and cleanup utility for iPhone 14 Pro Max users, in a Dark OLED Cyberpunk style with restrained iOS glass surfaces, dial ENERGY 2 / RHYTHM 2 / MOTION 1.

## 2. Three Dials
- **ENERGY: 2 (Balanced)** - Sharp technical diagnostic utility with clear hierarchy and high-contrast electric cyan focus, avoiding noisy clutter.
- **RHYTHM: 2 (Consistent with intentional breaks)** - Top glass capacity HUD breaks visually from the flat OLED ranked list rows and floating glass action dock.
- **MOTION: 1 (Restrained)** - Snappy iOS spring state transitions on selection, progress bar updates, and preview sheets; no continuous floating or pulsing loops.

## 3. Color System (WCAG AA Verified on OLED #000000 & #0D1017)
- **Neutrals (OLED foundation):**
  - Canvas: `#000000` (true OLED black for power efficiency and contrast on Super Retina XDR)
  - Elevated Surface: `#0D1017` (opaque obsidian surface for ranked file rows and cards)
  - Hairline Border: `#1E2533` (1px structural separation)
  - Text Primary: `#F4F7FB` (19.54:1 on `#000000`, 17.71:1 on `#0D1017`)
  - Text Secondary: `#9AA5B8` (8.45:1 on `#000000`, 7.66:1 on `#0D1017`)
- **Active Palette (2 semantic cores + 1 primary accent):**
  - Primary Accent (`cyberCyan`): `#00E5FF` (13.65:1 on `#000000`; `#041016` text on cyan CTA gives 12.51:1)
  - Destructive Core (`cyberCrimson`): `#B80F3E` fill with `#FFFFFF` text (6.61:1) for delete actions; `#FF5C8A` text on dark (7.15:1)
  - Reclaimed Core (`acidMint`): `#2EE6A6` (12.99:1 on `#000000`) for freed storage readout

## 4. Typography
- **UI Headings & Labels:** System SF Pro (`Display` / `Text`) for crisp native legibility in Indonesian.
- **Numeric Telemetry & File Sizes:** `.monospacedDigit()` and `SF Mono` strictly for GB/MB counts, video durations, and file paths so columns stay aligned during scans.

## 5. Purpose-Gate & Dose Caps
- **Glassmorphism (R-10, max 2 surfaces):** Native `.ultraThinMaterial` + 1px cyan/white edge border applied ONLY to (1) Top Sticky Storage HUD and (2) Bottom Floating Dock / Contextual Batch Delete Bar. Regular rows stay flat `#0D1017`.
- **Glow (R-13, max 2 elements):** Subtle cyan glow (`radius: 10, opacity: 0.25`) ONLY on the storage telemetry bar fill and active floating batch action dock.
- **Icons (R-04):** SF Symbols mapped directly to file types (`film`, `photo`, `camera.viewfinder`, `doc.on.doc`, `folder`, `trash`, `internaldrive`).
- **Placeholder Asset Note (R-23):** App name (`ByteReaper`) and minimal geometric cyan-ring `AppIcon` PNG are clearly marked placeholders ready to customize.

