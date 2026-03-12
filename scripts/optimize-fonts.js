/**
 * Font optimizer for Keitaro landing pages.
 *
 * Analyzes HTML + CSS, finds which @font-face combos are actually used,
 * removes unused ones, adds font-display: swap, reports unused font files.
 *
 * Usage: node optimize-fonts.js <projectDir> [--dry-run] [--html=index.php]
 *
 * Output: JSON to stdout with results.
 */

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const projectDir = args.find(a => !a.startsWith('--'));
const dryRun = args.includes('--dry-run');
const htmlFileArg = args.find(a => a.startsWith('--html='));
const htmlFile = htmlFileArg ? htmlFileArg.split('=')[1] : 'index.php';

if (!projectDir) {
  console.error('Usage: node optimize-fonts.js <projectDir> [--dry-run] [--html=index.php]');
  process.exit(1);
}

const result = {
  dryRun,
  fontFacesBefore: 0,
  fontFacesAfter: 0,
  fontFacesRemoved: 0,
  fontFilesTotal: 0,
  fontFilesUnused: 0,
  fontFilesSizeBeforeKB: 0,
  fontFilesSizeAfterKB: 0,
  addedFontDisplaySwap: 0,
  removedUnicodeRanges: [],
  removedCombos: [],
  keptCombos: [],
  unusedFiles: [],
  legacyFormatsRemoved: 0,
  legacyFilesDeleted: 0,
  legacyFilesSizeKB: 0,
  errors: []
};

try {
  // 1. Read HTML
  const htmlPath = path.join(projectDir, htmlFile);
  if (!fs.existsSync(htmlPath)) {
    // Try .lh.audit.html
    const auditPath = path.join(projectDir, '.lh.audit.html');
    if (!fs.existsSync(auditPath)) {
      throw new Error(`HTML file not found: ${htmlPath}`);
    }
  }
  const html = fs.readFileSync(htmlPath, 'utf8');

  // 2. Find all CSS files referenced in HTML
  const cssRefs = [...html.matchAll(/<link[^>]*href=["']([^"']+\.css)["'][^>]*>/gi)];
  const cssFiles = [];
  for (const ref of cssRefs) {
    const rel = ref[1];
    if (rel.startsWith('http')) continue;
    const abs = path.join(projectDir, rel);
    if (fs.existsSync(abs)) cssFiles.push({ rel, abs });
  }

  // 3. Read all CSS content (non-font-face CSS for analysis)
  let allCssContent = html;
  const cssByFile = {};
  for (const { rel, abs } of cssFiles) {
    const content = fs.readFileSync(abs, 'utf8');
    cssByFile[abs] = content;
    allCssContent += '\n' + content;
  }

  // 4. Detect page language/charset to determine needed unicode ranges
  const langMatch = html.match(/<html[^>]*lang=["']([^"']+)["']/i);
  const pageLang = langMatch ? langMatch[1].toLowerCase() : 'en';

  // Determine which unicode range categories are needed
  const neededRanges = new Set(['latin']); // always need latin
  if (/^(pl|cs|sk|hu|ro|hr|sl|lt|lv|et|tr)/.test(pageLang)) {
    neededRanges.add('latin-ext');
  }
  if (/^(es|pt|fr|it|de|nl|sv|da|no|fi|ca|gl|eu)/.test(pageLang)) {
    neededRanges.add('latin-ext'); // accented chars
  }
  if (/^(ru|uk|bg|sr|mk|be|kk)/.test(pageLang)) {
    neededRanges.add('cyrillic');
    neededRanges.add('cyrillic-ext');
  }
  if (/^vi/.test(pageLang)) {
    neededRanges.add('vietnamese');
  }

  // Also scan actual text content for non-latin chars
  const textContent = html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
  const hasCyrillic = /[\u0400-\u04FF]/.test(textContent);
  const hasVietnamese = /[\u0102\u0103\u0110\u0111\u0128\u0129]/.test(textContent);
  if (hasCyrillic) { neededRanges.add('cyrillic'); neededRanges.add('cyrillic-ext'); }
  if (hasVietnamese) neededRanges.add('vietnamese');

  // 5. Find actually used font combos from CSS rules (excluding @font-face blocks)
  // Only track Google Fonts families for pruning — icon fonts and other
  // non-Google @font-face blocks must never be removed.
  const googleFonts = ['Montserrat', 'Roboto', 'Roboto Slab', 'Open Sans',
    'Open Sans Hebrew Condensed', 'Open Sans Condensed', 'Open Sans Hebrew',
    'Lato', 'Poppins', 'Rubik', 'Fjalla One', 'Nunito Sans', 'Source Sans Pro',
    'Raleway', 'Inter', 'Oswald', 'Playfair Display', 'PT Sans', 'Ubuntu',
    'Noto Sans', 'Merriweather', 'Fira Sans', 'Work Sans', 'Barlow', 'Mukta',
    'Quicksand', 'Heebo', 'DM Sans', 'Manrope', 'Outfit'];
  const cssWithoutFontFace = allCssContent.replace(/@font-face\s*\{[^}]*\}/gs, '');
  const usedCombos = new Set();

  // Extract from CSS rule blocks
  const ruleBlocks = [...cssWithoutFontFace.matchAll(/\{([^}]*)\}/gs)];
  for (const block of ruleBlocks) {
    const text = block[1];
    const familyMatch = text.match(/font-family\s*:\s*['"]?([^;'"}\n!,]+)/i);
    if (!familyMatch) continue;
    const fam = familyMatch[1].trim().replace(/['"]$/, '');
    if (!googleFonts.includes(fam)) continue;

    let weight = '400';
    const weightMatch = text.match(/font-weight\s*:\s*(\d+|bold|normal|lighter|bolder)/i);
    if (weightMatch) {
      weight = weightMatch[1];
      if (weight === 'bold') weight = '700';
      if (weight === 'normal') weight = '400';
      if (weight === 'lighter') weight = '300';
      if (weight === 'bolder') weight = '800';
    }

    let style = 'normal';
    const styleMatch = text.match(/font-style\s*:\s*(italic|normal|oblique)/i);
    if (styleMatch) style = styleMatch[1] === 'oblique' ? 'italic' : styleMatch[1];

    usedCombos.add(`${fam}|${style}|${weight}`);
  }

  // 6. Process each CSS file that has @font-face
  const allReferencedFonts = new Set();
  const allKeptFonts = new Set();

  for (const { abs } of cssFiles) {
    const content = cssByFile[abs];
    if (!content.includes('@font-face')) continue;

    // Parse all @font-face blocks
    const fontFaceRegex = /@font-face\s*\{([^}]*)\}/gs;
    let match;
    const fontFaces = [];

    while ((match = fontFaceRegex.exec(content)) !== null) {
      const block = match[0];
      const inner = match[1];

      const familyM = inner.match(/font-family\s*:\s*['"]([^'"]+)['"]/i);
      const weightM = inner.match(/font-weight\s*:\s*(\d+)/i);
      const styleM = inner.match(/font-style\s*:\s*(\w+)/i);
      const srcM = inner.match(/url\(["']([^"']+)["']\)/i);
      const rangeComment = content.substring(Math.max(0, match.index - 30), match.index);
      const rangeLabel = rangeComment.match(/\/\*\s*([\w-]+)\s*\*\//);

      // Collect referenced font file
      if (srcM) {
        const fontRel = srcM[1].replace(/^\.\//, '');
        allReferencedFonts.add(fontRel);
      }

      fontFaces.push({
        block,
        family: familyM ? familyM[1] : null,
        weight: weightM ? weightM[1] : '400',
        style: styleM ? styleM[1] : 'normal',
        src: srcM ? srcM[1] : null,
        unicodeRange: rangeLabel ? rangeLabel[1] : 'unknown',
        index: match.index
      });
    }

    result.fontFacesBefore += fontFaces.length;

    // Decide which to keep
    let newContent = content;
    const toRemove = [];

    for (const ff of fontFaces) {
      if (!ff.family) continue;

      const combo = `${ff.family}|${ff.style}|${ff.weight}`;
      const isGoogleFont = googleFonts.includes(ff.family);
      const isUsedCombo = usedCombos.has(combo);
      const isNeededRange = neededRanges.has(ff.unicodeRange) || ff.unicodeRange === 'unknown';

      // Non-Google fonts (icon fonts, custom fonts) are always kept
      if (!isGoogleFont) {
        result.keptCombos.push(combo + ' (non-google, kept)');
        if (ff.src) { allKeptFonts.add(ff.src.replace(/^\.\//, '')); }
        continue;
      }

      if (!isUsedCombo) {
        toRemove.push(ff);
        result.removedCombos.push(combo + ' (' + ff.unicodeRange + ')');
      } else if (!isNeededRange) {
        toRemove.push(ff);
        result.removedUnicodeRanges.push(combo + ' [' + ff.unicodeRange + ']');
      } else {
        result.keptCombos.push(combo + ' (' + ff.unicodeRange + ')');
        if (ff.src) {
          allKeptFonts.add(ff.src.replace(/^\.\//, ''));
        }
      }
    }

    // Remove unused @font-face blocks
    for (const ff of toRemove) {
      // Also remove preceding comment line
      const beforeBlock = newContent.substring(0, newContent.indexOf(ff.block));
      const commentEnd = beforeBlock.lastIndexOf('*/');
      const commentStart = beforeBlock.lastIndexOf('/*');
      let removeFrom = newContent.indexOf(ff.block);
      if (commentStart !== -1 && commentEnd !== -1 && commentEnd > commentStart &&
          removeFrom - commentStart < 40) {
        removeFrom = commentStart;
      }
      const removeEnd = newContent.indexOf(ff.block) + ff.block.length;
      newContent = newContent.substring(0, removeFrom) + newContent.substring(removeEnd);
    }

    result.fontFacesRemoved += toRemove.length;

    // Add or fix font-display: swap in remaining @font-face
    // Also replace font-display: block with swap (FA uses block by default)
    let swapCount = 0;
    newContent = newContent.replace(/@font-face\s*\{([^}]*)\}/gs, (match, inner) => {
      if (!/font-display\s*:/i.test(inner)) {
        swapCount++;
        return match.replace(/(\n\s*src:)/, '\n  font-display: swap;$1');
      }
      if (/font-display\s*:\s*block/i.test(inner)) {
        swapCount++;
        return match.replace(/font-display\s*:\s*block/i, 'font-display: swap');
      }
      return match;
    });
    result.addedFontDisplaySwap += swapCount;

    // Remove legacy font formats from @font-face src declarations
    // Keep woff2 and woff; remove eot (including ?#iefix), ttf, svg entries
    newContent = newContent.replace(/@font-face\s*\{([^}]*)\}/gs, (faceMatch, inner) => {
      if (!/src\s*:/i.test(inner)) return faceMatch;

      // Remove standalone eot-only src lines (IE9 compat lines before multi-format src)
      let cleaned = faceMatch.replace(
        /\n[ \t]*src\s*:\s*url\(["']?[^"')]*\.eot["']?\)\s*;/gi,
        ''
      );

      // Process multi-format src lines
      cleaned = cleaned.replace(
        /(src\s*:)([\s\S]*?);(?=\s*(?:font-|unicode-range|\}))/g,
        (srcMatch, prop, value) => {
          const entries = value.split(/,(?=\s*(?:url|local)\s*\()/i);
          const kept = [];
          let removed = 0;

          for (const entry of entries) {
            const isLegacy = /url\(["']?[^"')]*\.(?:eot|ttf|svg)[^"')]*["']?\)/i.test(entry);
            if (isLegacy) {
              removed++;
            } else {
              kept.push(entry);
            }
          }

          // If no modern entries remain, leave src unchanged (safety guard)
          if (kept.length === 0) return srcMatch;

          result.legacyFormatsRemoved += removed;
          const rebuilt = kept.join(',').replace(/,\s*$/, '').trimEnd();
          return prop + rebuilt + ';';
        }
      );

      return cleaned;
    });

    // Clean up multiple blank lines
    newContent = newContent.replace(/\n{3,}/g, '\n\n');

    if (!dryRun && newContent !== content) {
      fs.writeFileSync(abs, newContent, 'utf8');
    }
  }

  result.fontFacesAfter = result.fontFacesBefore - result.fontFacesRemoved;

  // 7. Find unused font files
  const fontsDir = path.join(projectDir, 'css', 'fonts');
  if (fs.existsSync(fontsDir)) {
    const allFontFiles = fs.readdirSync(fontsDir).filter(f => /\.(woff2?|ttf|eot|svg)$/i.test(f));
    result.fontFilesTotal = allFontFiles.length;

    let totalSizeBefore = 0;
    let totalSizeAfter = 0;

    for (const f of allFontFiles) {
      const filePath = path.join(fontsDir, f);
      const size = fs.statSync(filePath).size;
      totalSizeBefore += size;

      const relPath = 'fonts/' + f;
      if (!allKeptFonts.has(relPath)) {
        result.unusedFiles.push(f);
        result.fontFilesUnused++;

        if (!dryRun) {
          fs.unlinkSync(filePath);
        }
      } else {
        totalSizeAfter += size;
      }

      // Move legacy format files when a woff2 equivalent exists
      if (/\.(eot|ttf|svg)$/i.test(f) && fs.existsSync(filePath)) {
        const baseName = path.basename(f, path.extname(f));
        const woff2Path = path.join(fontsDir, baseName + '.woff2');
        if (fs.existsSync(woff2Path)) {
          result.legacyFilesDeleted++;
          result.legacyFilesSizeKB += Math.round(size / 1024);
          if (!dryRun) {
            if (fs.existsSync(filePath)) {
              fs.unlinkSync(filePath);
            }
          }
        }
      }
    }

    result.fontFilesSizeBeforeKB = Math.round(totalSizeBefore / 1024);
    result.fontFilesSizeAfterKB = Math.round(totalSizeAfter / 1024);
  }

  // Deduplicate arrays
  result.removedCombos = [...new Set(result.removedCombos)];
  result.keptCombos = [...new Set(result.keptCombos)];

} catch (e) {
  result.errors.push(e.message);
}

console.log(JSON.stringify(result, null, 2));
