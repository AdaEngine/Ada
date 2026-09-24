(function installAdaEngineDocCTheme(root, makeTheme) {
  const theme = makeTheme(root);

  if (typeof module === "object" && module.exports) {
    module.exports = theme;
  }

  root.AdaEngineDocCTheme = theme;
  if (typeof document !== "undefined") {
    theme.install(document);
  }
})(typeof globalThis === "undefined" ? this : globalThis, function makeAdaEngineDocCTheme(runtime) {
  "use strict";

  const keywords = new Set([
    "_args", "_func", "and", "async", "await", "break", "case", "class", "const", "continue", "default", "else", "enum", "event", "extern", "false",
    "file", "for", "func", "if", "import", "in", "internal", "is", "lazy", "module", "not", "null", "or", "private", "public", "repeat",
    "return", "static", "struct", "super", "switch", "true", "undefined", "var", "while"
  ]);
  const punctuation = new Set(Array.from("{}[]();:,.+-*/%=!<>&|^~?"));
  const identifierStart = /[A-Za-z_]/;
  const identifierPart = /[A-Za-z0-9_]/;
  const numberPattern = /^(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|(?:\d[\d_]*\.?[\d_]*|\.\d[\d_]*)(?:[eE][+-]?\d[\d_]*)?)/;

  function appendToken(tokens, type, text) {
    if (!text) {
      return;
    }

    const previous = tokens[tokens.length - 1];
    if (previous && previous.type === type) {
      previous.text += text;
    } else {
      tokens.push({ type, text });
    }
  }

  function scanBlockComment(line, start, state) {
    let index = start;
    while (index < line.length) {
      if (line.startsWith("/*", index)) {
        state.blockCommentDepth += 1;
        index += 2;
      } else if (line.startsWith("*/", index)) {
        state.blockCommentDepth -= 1;
        index += 2;
        if (state.blockCommentDepth === 0) {
          break;
        }
      } else {
        index += 1;
      }
    }
    return index;
  }

  function lexAdaScriptLine(line, state = { blockCommentDepth: 0 }) {
    const tokens = [];
    let index = 0;

    while (index < line.length) {
      if (state.blockCommentDepth > 0) {
        const end = scanBlockComment(line, index, state);
        appendToken(tokens, "comment", line.slice(index, end));
        index = end;
        continue;
      }

      if (line.startsWith("//", index)) {
        appendToken(tokens, "comment", line.slice(index));
        break;
      }

      if (line.startsWith("/*", index)) {
        const end = scanBlockComment(line, index, state);
        appendToken(tokens, "comment", line.slice(index, end));
        index = end;
        continue;
      }

      const character = line[index];
      if (character === "\"" || character === "'") {
        const quote = character;
        let end = index + 1;
        while (end < line.length) {
          if (line[end] === "\\") {
            end = Math.min(end + 2, line.length);
          } else if (line[end] === quote) {
            end += 1;
            break;
          } else {
            end += 1;
          }
        }
        appendToken(tokens, "string", line.slice(index, end));
        index = end;
        continue;
      }

      if (character === "@" && identifierStart.test(line[index + 1] || "")) {
        let end = index + 2;
        while (identifierPart.test(line[end] || "")) {
          end += 1;
        }
        appendToken(tokens, "annotation", line.slice(index, end));
        index = end;
        continue;
      }

      const number = line.slice(index).match(numberPattern);
      if (number && (/[0-9]/.test(character) || (character === "." && /[0-9]/.test(line[index + 1] || "")))) {
        appendToken(tokens, "number", number[0]);
        index += number[0].length;
        continue;
      }

      if (identifierStart.test(character)) {
        let end = index + 1;
        while (identifierPart.test(line[end] || "")) {
          end += 1;
        }
        const word = line.slice(index, end);
        if (keywords.has(word.toLowerCase())) {
          appendToken(tokens, "keyword", word);
        } else if (/^[A-Z]/.test(word)) {
          appendToken(tokens, "type", word);
        } else {
          appendToken(tokens, "plain", word);
        }
        index = end;
        continue;
      }

      if (punctuation.has(character)) {
        appendToken(tokens, "punctuation", character);
      } else {
        appendToken(tokens, "plain", character);
      }
      index += 1;
    }

    return tokens;
  }

  function highlightListing(listing, documentObject) {
    if (listing.dataset.adaengineHighlighted === "true") {
      return;
    }

    const state = { blockCommentDepth: 0 };
    listing.querySelectorAll(".code-line").forEach((line) => {
      const fragment = documentObject.createDocumentFragment();
      lexAdaScriptLine(line.textContent || "", state).forEach((token) => {
        if (token.type === "plain") {
          fragment.append(documentObject.createTextNode(token.text));
          return;
        }

        const span = documentObject.createElement("span");
        span.className = `ada-token-${token.type}`;
        span.textContent = token.text;
        fragment.append(span);
      });
      line.replaceChildren(fragment);
    });
    listing.dataset.adaengineHighlighted = "true";
  }

  function install(documentObject) {
    let animationFrame;
    const highlight = () => {
      animationFrame = undefined;
      documentObject.querySelectorAll('.code-listing[data-syntax="ada"], .code-listing[data-syntax="gravity"]').forEach((listing) => {
        highlightListing(listing, documentObject);
      });
    };
    const scheduleHighlight = () => {
      if (animationFrame === undefined) {
        animationFrame = runtime.requestAnimationFrame(highlight);
      }
    };

    if (documentObject.readyState === "loading") {
      documentObject.addEventListener("DOMContentLoaded", scheduleHighlight, { once: true });
    } else {
      scheduleHighlight();
    }

    const observer = new runtime.MutationObserver(scheduleHighlight);
    observer.observe(documentObject.documentElement, { childList: true, subtree: true });
  }

  return { highlightListing, install, lexAdaScriptLine };
});
