# Image Sizing Skill

Calculate correct `sizes` attributes for Next.js `<Image>` components based on actual rendered widths at each breakpoint.

## Why It Matters
The `sizes` attribute tells the browser what width an image will render at each viewport size. Incorrect sizes = wrong image downloaded = blurry images or wasted bandwidth.

## Methodology

### Step 1: Identify Container Width at Each Breakpoint
Trace the CSS from the image up to the viewport:
- What is the parent container width? (max-w-7xl = 1280px, percentage, calc, etc.)
- What padding exists? (px-4 = 1rem each side = 2rem total)
- Is it in a grid? How many columns at each breakpoint?
- Any flex ratios? (flex-1 vs flex-[1.5])

### Step 2: Calculate Image Width at Each Breakpoint
For each Tailwind breakpoint used in the layout:

| Breakpoint | Prefix | Width |
|-----------|--------|-------|
| Mobile | (default) | < 640px |
| sm | sm: | >= 640px |
| md | md: | >= 768px |
| lg | lg: | >= 1024px |
| xl | xl: | >= 1280px |

**Formula:** `image_width = (container_width - total_padding - total_gaps) / num_columns * flex_ratio`

### Step 3: Build the sizes Attribute
Format: `(max-width: Xpx) calc_for_that_range, (max-width: Ypx) calc_for_next_range, desktop_value`

- Use `calc()` for dynamic widths (percentage or viewport-relative containers)
- Use fixed `px` values for fixed-width containers (e.g., 600px image container)
- Use `min()` when capped by max-width (e.g., `min(33vw, 427px)`)

### Step 4: Verify
The sizes attribute breakpoints should match the CSS breakpoints where the layout changes (grid column count changes, container width changes, etc.)

## Common Patterns

### Full-width image in max-w-7xl container with responsive padding
```
sizes="(max-width: 639px) calc(100vw - 2rem), (max-width: 1023px) calc(100vw - 3rem), calc(min(100vw, 80rem) - 4rem)"
```
- Mobile: 100vw - px-4 (2rem)
- Tablet: 100vw - px-6 (3rem)
- Desktop: min(viewport, 1280px) - px-8 (4rem)

### Grid with 1/2/3 columns in max-w-7xl
```
sizes="(max-width: 639px) calc(100vw - 2rem), (max-width: 767px) calc((100vw - 3rem) / 2), min(33vw, 427px)"
```
- Mobile: full width - padding
- sm (2 cols): (viewport - padding) / 2
- md+ (3 cols): 33vw capped at 1280/3 = 427px

### Flex children with known ratios
For flex-1 and flex-[1.5] in a 600px container:
- flex-1 share: 1/2.5 = 0.4 -> 240px
- flex-[1.5] share: 1.5/2.5 = 0.6 -> 360px

## Checklist
- [ ] sizes breakpoints match CSS layout breakpoints
- [ ] Account for padding at each breakpoint
- [ ] Account for grid gaps
- [ ] Account for flex ratios
- [ ] Use calc() for dynamic containers, px for fixed
- [ ] Cap with min() when max-width constrains the container
- [ ] Verify: no breakpoint says image is bigger than it actually renders
