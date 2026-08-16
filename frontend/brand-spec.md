# MoonSage Frontend Brand Specification

## Direction

MoonSage is a high-density MoonBit development workspace. Its visual direction
is informed by the restrained developer-tool language of the MoonBit Chinese
website, reviewed at <https://www.moonbitlang.cn/>. The implementation does not
copy or hotlink MoonBit artwork, logos, screenshots, or other site assets.

MoonSage uses a standalone text wordmark. The official MoonBit rabbit is not a
MoonSage logo and must not be placed in the product chrome.

## Color

| Role | Light | Dark |
| --- | --- | --- |
| Canvas | `#ffffff` | `#17181f` |
| Subtle surface | `#f8fafc` | `#1b1b1d` |
| Raised surface | `#ffffff` | `#242526` |
| Primary text | `#111827` | `#e3e3e3` |
| Muted text | `#6b7280` | `#a1a1aa` |
| Brand accent | `#b92482` | `#e040b0` |

Brand magenta is reserved for focus, selection, progress, and primary actions.
Success, warning, and danger colors remain semantic and visually secondary.

## Typography

- Interface: Manrope, PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif.
- Code and paths: Menlo, Consolas, Liberation Mono, monospace.
- Compact controls use 12-14 px type; conversation copy uses 15-16 px type.
- Letter spacing is zero.

## Shape And Motion

- Spacing follows a 4 px base grid, with 8 px as the normal component rhythm.
- Controls use 6 px radii; framed panels use 8-12 px radii.
- Shadows are limited to drawers, menus, and the composer.
- Motion uses short opacity/color/transform transitions and honors
  `prefers-reduced-motion`.

## Icons

Icons are a local subset of Lucide Static 0.468.0 under `assets/icons/`.
They are served locally and displayed as CSS masks so their color follows the
active theme. Lucide Static is licensed under the ISC License; the required
notice is stored in `assets/icons/LICENSE.txt`.
