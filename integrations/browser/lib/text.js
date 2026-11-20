// Text extraction and sentence chunking.
// Runs in pages (DOM available) and in the service worker (chunkText only).
(function (global) {
  "use strict";

  const SKIP_TAGS = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "VIDEO",
    "AUDIO", "OBJECT", "EMBED", "BUTTON", "INPUT", "SELECT", "OPTION", "TEXTAREA",
    "HEAD", "META", "LINK"
  ]);

  const BLOCK_TAGS = new Set([
    "ADDRESS", "ARTICLE", "ASIDE", "BLOCKQUOTE", "CAPTION", "DD", "DETAILS", "DIV",
    "DL", "DT", "FIELDSET", "FIGCAPTION", "FIGURE", "FOOTER", "FORM", "H1", "H2",
    "H3", "H4", "H5", "H6", "HEADER", "HR", "LI", "MAIN", "NAV", "OL", "P", "PRE",
    "SECTION", "SUMMARY", "TABLE", "TBODY", "TD", "TFOOT", "TH", "THEAD", "TR", "UL",
    "BR"
  ]);

  function isVisible(el) {
    if (el.checkVisibility) {
      return el.checkVisibility({ checkOpacity: false, checkVisibilityCSS: true });
    }
    const cs = getComputedStyle(el);
    return cs.display !== "none" && cs.visibility !== "hidden";
  }

  function buildIndex(root, opts) {
    opts = opts || {};
    const clip = opts.clip || null;
    const skip = opts.skip || null;
    const parts = [];
    const segments = [];
    let len = 0;

    function walk(node) {
      if (node.nodeType === 3) {
        let s = 0;
        let e = node.nodeValue ? node.nodeValue.length : 0;
        if (clip) {
          try {
            if (!clip.intersectsNode(node)) return;
          } catch (err) {
            return;
          }
          if (clip.startContainer === node) s = clip.startOffset;
          if (clip.endContainer === node) e = clip.endOffset;
        }
        if (e <= s) return;
        segments.push({ node: node, start: len, offset: s, len: e - s });
        parts.push(node.nodeValue.slice(s, e));
        len += e - s;
        return;
      }
      if (node.nodeType !== 1) return;
      if (skip && skip.has(node)) return;
      const tag = node.tagName.toUpperCase();
      if (SKIP_TAGS.has(tag)) return;
      if (node.getAttribute("aria-hidden") === "true") return;
      if (!isVisible(node)) return;
      if (clip) {
        try {
          if (!clip.intersectsNode(node)) return;
        } catch (err) {
          return;
        }
      }
      const block = BLOCK_TAGS.has(tag);
      if (block) {
        parts.push("\n");
        len += 1;
      }
      for (let c = node.firstChild; c; c = c.nextSibling) walk(c);
      if (block) {
        parts.push("\n");
        len += 1;
      }
    }

    walk(root);
    return { raw: parts.join(""), segments: segments };
  }

  // Collapse runs of whitespace, keep newlines as paragraph breaks.
  // map[i] is the index in the raw string of the normalized char i.
  function normalize(text) {
    const out = [];
    const map = [];
    const n = text.length;
    let i = 0;
    while (i < n) {
      const ch = text[i];
      if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n" || ch === "\u00a0") {
        let j = i;
        let newline = false;
        while (j < n) {
          const c = text[j];
          if (c === "\n" || c === "\r") newline = true;
          else if (c !== " " && c !== "\t" && c !== "\u00a0") break;
          j++;
        }
        if (out.length) {
          const sep = newline ? "\n" : " ";
          if (!(sep === "\n" && out[out.length - 1] === "\n")) {
            out.push(sep);
            map.push(i);
          }
        }
        i = j;
      } else {
        out.push(ch);
        map.push(i);
        i++;
      }
    }
    while (out.length) {
      const last = out[out.length - 1];
      if (last !== " " && last !== "\n") break;
      out.pop();
      map.pop();
    }
    return { text: out.join(""), map: map };
  }

  let segmenter = null;

  function splitSentences(para) {
    const out = [];
    if (typeof Intl !== "undefined" && Intl.Segmenter) {
      if (!segmenter) segmenter = new Intl.Segmenter(undefined, { granularity: "sentence" });
      for (const part of segmenter.segment(para)) {
        out.push([part.index, part.index + part.segment.length]);
      }
    } else {
      const re = /[^.!?\n]+[.!?]+(?=\s|$)|[^.!?\n]+$/g;
      let m;
      while ((m = re.exec(para))) out.push([m.index, m.index + m[0].length]);
    }
    return out.length ? out : [[0, para.length]];
  }

  function trimStart(text, s, e) {
    while (s < e && /\s/.test(text[s])) s++;
    return s;
  }

  function trimEnd(text, s, e) {
    while (e > s && /\s/.test(text[e - 1])) e--;
    return e;
  }

  // Split text into speakable chunks, the same way the Talk to Me app does
  // (src/text/chunk.zig): one sentence per chunk; sentences longer than
  // CLAUSE_LEN split at clause boundaries (, ; : dashes); MAX_LEN is the hard
  // cap (then a space); the first chunk is cut at its first clause when long.
  // Short chunks keep first audio and interrupts quick, and keep the page
  // highlight in step with what is spoken.
  const CLAUSE_LEN = 100;
  const FIRST_LEN = 60;
  const MIN_PIECE = 20;

  function clauseBreakBefore(text, s, lo, hi) {
    for (let i = Math.min(hi, text.length - 1); i > s + lo; i--) {
      if (/[,;:\u2014\u2013]/.test(text[i - 1]) && /\s/.test(text[i] || "")) return i;
    }
    return -1;
  }

  function clauseBreakAfter(text, s, lo, hi) {
    for (let i = s + lo; i < Math.min(hi, text.length); i++) {
      if (/[,;:\u2014\u2013]/.test(text[i - 1]) && /\s/.test(text[i] || "")) return i;
    }
    return -1;
  }

  function chunkText(text, maxLen) {
    const max = Math.max(80, Math.min((maxLen | 0) || 150, 150));
    const pieces = [];
    let pStart = 0;
    const push = (s, e) => {
      while (s < e && /\s/.test(text[s])) s++;
      while (e > s && /\s/.test(text[e - 1])) e--;
      if (e > s) pieces.push({ s: s, e: e });
    };

    for (let i = 0; i <= text.length; i++) {
      if (i !== text.length && text[i] !== "\n") continue;
      if (i > pStart) {
        const para = text.slice(pStart, i);
        for (const range of splitSentences(para)) {
          let s = pStart + range[0];
          const e = pStart + range[1];
          // short first chunk: time to first audio scales with its length
          if (!pieces.length && e - s > FIRST_LEN) {
            const cut = clauseBreakBefore(text, s, 12, s + FIRST_LEN + 30);
            if (cut > 0) {
              push(s, cut);
              s = cut;
            }
          }
          while (e - s > CLAUSE_LEN) {
            let cut = clauseBreakBefore(text, s, MIN_PIECE, s + CLAUSE_LEN);
            if (cut < 0) cut = clauseBreakAfter(text, s, CLAUSE_LEN, s + max);
            if (cut < 0) {
              if (e - s <= max) break;
              cut = s + max;
              while (cut > s + max / 3 && !/\s/.test(text[cut])) cut--;
              if (cut <= s + max / 3) cut = s + max;
            }
            if (e - cut < MIN_PIECE / 2) break; // don't leave a tiny tail
            push(s, cut);
            s = cut;
          }
          push(s, e);
        }
      }
      pStart = i + 1;
    }

    return pieces.map(function (c) {
      return { start: c.s, end: c.e, text: text.slice(c.s, c.e) };
    });
  }

  function findSeg(segments, idx, isEnd) {
    const key = isEnd ? idx - 1 : idx;
    let lo = 0;
    let hi = segments.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const seg = segments[mid];
      if (key < seg.start) hi = mid - 1;
      else if (key >= seg.start + seg.len) lo = mid + 1;
      else return seg;
    }
    return null;
  }

  function makeRange(segments, rawStart, rawEnd) {
    const a = findSeg(segments, rawStart, false);
    const b = findSeg(segments, rawEnd, true);
    if (!a || !b) return null;
    try {
      const r = document.createRange();
      const aOff = a.offset + Math.min(Math.max(rawStart - a.start, 0), a.len);
      const bOff = b.offset + Math.min(Math.max(rawEnd - b.start, 0), b.len);
      r.setStart(a.node, aOff);
      r.setEnd(b.node, bOff);
      return r;
    } catch (err) {
      return null;
    }
  }

  function chunksFromRoot(root, maxLen, clip) {
    if (!root) return [];
    const index = buildIndex(root, { clip: clip });
    const norm = normalize(index.raw);
    if (!norm.text.trim()) return [];
    return chunkText(norm.text, maxLen).map(function (part) {
      const rawStart = norm.map[part.start];
      const rawEnd = norm.map[part.end - 1] + 1;
      return { text: part.text, range: makeRange(index.segments, rawStart, rawEnd) };
    });
  }

  // Chunks for arbitrary text, no DOM ranges (used by the popup and CLI paths).
  function chunksFromText(text, maxLen) {
    const norm = normalize(String(text || ""));
    if (!norm.text.trim()) return [];
    return chunkText(norm.text, maxLen).map(function (part) {
      return { text: part.text, range: null };
    });
  }

  // ---------- extraction roots ----------

  function textLen(el) {
    return (el.innerText || el.textContent || "").trim().length;
  }

  function linkDensity(el) {
    const total = (el.textContent || "").length;
    if (!total) return 0;
    let links = 0;
    for (const a of el.querySelectorAll("a[href]")) {
      links += (a.textContent || "").length;
    }
    return links / total;
  }

  function depth(el) {
    let d = 0;
    for (let n = el; n && n.parentElement; n = n.parentElement) d++;
    return d;
  }

  function isEditableDoc(el) {
    return el.matches("[contenteditable='true'], .ProseMirror");
  }

  function documentRoot() {
    const vw = innerWidth;
    const vh = innerHeight;
    const viewArea = Math.max(1, vw * vh);

    // an open editor or document panel wins
    const editors = [];
    for (const el of document.querySelectorAll("[contenteditable='true'], .ProseMirror")) {
      if (isEditableDoc(el) && textLen(el) >= 200) editors.push(el);
    }
    if (editors.length) {
      editors.sort(function (a, b) {
        return depth(b) - depth(a);
      });
      return { el: editors[0], kind: "document" };
    }

    // the scrollable panel that fills the viewport
    const scrollables = [];
    for (const el of document.querySelectorAll("div,section,article,main,td")) {
      const cs = getComputedStyle(el);
      if (!/(auto|scroll)/.test(cs.overflowY)) continue;
      if (el.scrollHeight <= el.clientHeight + 20) continue;
      const r = el.getBoundingClientRect();
      const w = Math.min(r.right, vw) - Math.max(r.left, 0);
      const h = Math.min(r.bottom, vh) - Math.max(r.top, 0);
      if (w <= 0 || h <= 0 || w * h < viewArea * 0.15) continue;
      const len = textLen(el);
      if (len < 400) continue;
      if (linkDensity(el) > 0.3) continue;
      scrollables.push({ el: el, len: len, depth: depth(el) });
    }
    if (scrollables.length) {
      const maxLen = Math.max.apply(null, scrollables.map(function (s) { return s.len; }));
      const good = scrollables
        .filter(function (s) { return s.len >= maxLen * 0.5; })
        .sort(function (a, b) { return b.depth - a.depth; });
      return { el: good[0].el, kind: "panel" };
    }

    // largest readable block on the page
    let best = null;
    let bestScore = 0;
    for (const el of document.querySelectorAll("main,article,section,div")) {
      const len = textLen(el);
      if (len < 400) continue;
      const score = len * (1 - linkDensity(el));
      if (score > bestScore) {
        bestScore = score;
        best = el;
      }
    }
    return { el: best || document.body, kind: "page" };
  }

  function mainRoot() {
    return document.querySelector("main") || document.querySelector("[role='main']") || document.body;
  }

  // Range that starts right after the last user message, so only the newest reply is read.
  const REPLY_SELECTOR =
    "[data-message-author-role='assistant'], [data-testid='chat-message-content'], .font-claude-message";

  function follows(ref, el) {
    return !!(ref.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
  }

  function commonAncestor(a, b) {
    for (let n = a; n; n = n.parentElement) {
      if (n.contains(b)) return n;
    }
    return null;
  }

  // Reply containers, outermost only: wrappers often contain nested matches.
  function replyElements() {
    const list = [];
    for (const el of document.querySelectorAll(REPLY_SELECTOR)) {
      if (textLen(el) > 20 && isVisible(el)) list.push(el);
    }
    return list.filter(function (el) {
      return !list.some(function (other) {
        return other !== el && other.contains(el);
      });
    });
  }

  function lastReplyClip() {
    const main = mainRoot();
    const users = [];
    for (const el of document.querySelectorAll("[data-testid='user-message'], [data-message-author-role='user']")) {
      if (main.contains(el) && textLen(el)) users.push(el);
    }
    const lastUser = users.length ? users[users.length - 1] : null;

    let replies = replyElements();
    if (lastUser) {
      replies = replies.filter(function (el) {
        return !lastUser.contains(el) && follows(lastUser, el);
      });
    }

    // clip to the reply containers only: trailing toolbars and chips stay out
    if (replies.length) {
      const first = replies[0];
      const last = replies[replies.length - 1];
      const root = commonAncestor(first, last) || main;
      try {
        const r = document.createRange();
        r.setStartBefore(first);
        r.setEndAfter(last);
        if (r.toString().trim().length > 20) return { root: root, clip: r };
      } catch (err) {
        // fall through
      }
    }

    if (lastUser) {
      try {
        const r = document.createRange();
        r.setStartAfter(lastUser);
        r.setEnd(main, main.childNodes.length);
        if (r.toString().trim().length > 20) return { root: main, clip: r };
      } catch (err) {
        // fall through
      }
    }

    for (let i = replies.length - 1; i >= 0; i--) {
      if (textLen(replies[i]) > 20) return { root: replies[i], clip: null };
    }
    return null;
  }

  // ---------- public API ----------

  function selectionChunks(maxLen) {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    const range = sel.getRangeAt(0);
    if (range.collapsed || !range.toString().trim()) return null;
    let root = range.commonAncestorContainer;
    if (root.nodeType === 3) root = root.parentElement;
    const chunks = chunksFromRoot(root, maxLen, range);
    return chunks.length ? { chunks: chunks, label: "Selection" } : null;
  }

  function replyChunks(maxLen) {
    const found = lastReplyClip();
    if (!found) return null;
    const chunks = chunksFromRoot(found.root, maxLen, found.clip);
    if (!chunks.length) return null;
    return { chunks: chunks, label: "Last reply" };
  }

  function pageChunks(maxLen) {
    const found = documentRoot();
    const chunks = chunksFromRoot(found.el, maxLen, null);
    if (!chunks.length) return null;
    return {
      chunks: chunks,
      label: found.kind === "document" ? "Document" : found.kind === "panel" ? "Visible panel" : document.title
    };
  }

  global.KokoroText = {
    chunkText: chunkText,
    chunksFromText: chunksFromText,
    chunksFromRoot: chunksFromRoot,
    selectionChunks: selectionChunks,
    replyChunks: replyChunks,
    pageChunks: pageChunks,
    documentRoot: documentRoot
  };
})(typeof self !== "undefined" ? self : this);
