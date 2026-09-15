# App 圖像

以內建 imagegen 產生 Bilibili 風格圖像；不是官方提供的圖檔。使用 sips 配合資產目錄尺寸縮放，窄版 Top Shelf 採中央裁切。Icon 採不透明前景與粉紅背層，使用兩層 imagestack。

資產位於 `BilibiliLive/Supporting Files/Assets.xcassets/App Icon & Top Shelf Image.brandassets/`。

- Icon：400×240、800×480、1280×768。
- Top Shelf：1920×720、3840×1440。
- Top Shelf Wide：2320×720、4640×1440。

## Icon 原始提示詞

Use case: logo-brand. Create a production tvOS app icon bitmap, landscape aspect ratio 5:3, ideally 1280x768. Bilibili official-app-inspired visual: completely flat solid Bilibili pink #FB7299 full-bleed rectangular background, crisp white iconic cute television outline with two diagonal antenna strokes, two short diagonal eyes and small playful zigzag mouth, perfectly centered, occupying 48 percent of canvas width and 62 percent height including antenna. Faithful clean geometric Bilibili small-TV character language. No lettering, no gradients, no shadows, no bevels, no rounded outside corners, no mockup, no border. Generous pink safe margins around the white symbol. Save generated image as a local file and return its path.

## Top Shelf 原始提示詞

以生成的 Icon 作為參考圖。

Create a matching Bilibili-inspired Apple TV top shelf background banner using this icon as a style reference. Very wide landscape 3.22:1 aspect, ideally 2320x720. Flat clean pink #FB7299 full-bleed background. In exact center put a crisp white Bilibili TV outline mascot matching reference, small enough to occupy only 17% canvas width and 52% canvas height. To the left and right at the far outer edges, extremely subtle lighter pink oversized outlines of the same television, partially outside the frame, opacity about 6%, quiet minimal tonal branding. Central 60% has ample negative space. Premium official-app visual simplicity. No words, no text, no slogans, no mockup, no dark shadows, no borders, no rounded canvas corners. This is a final bitmap banner not a presentation.

## 背層提示詞

Generate a completely uniform solid pink #FB7299 rectangular image, 5:3 landscape. Every pixel the same pink. No objects, no text, no logo, no gradients, no texture. This is the opaque back layer of a tvOS app icon.
