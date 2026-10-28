#!/usr/bin/env moon
---
-- HTML builder module.
-- Provides a function to easily create HTML tags.
-- @module html
---
:concat, :remove = table

---
-- Creates an HTML tag string.
-- The function is accessed via `html[tag_name]`.
-- It can take a variable number of arguments which can be
-- tables (treated as attributes for the tag),
-- functions (called to generate content),
-- strings or numbers (treated as content).
-- @tparam string k The HTML tag name (e.g., "div", "a", "p").
-- @param ... Arguments for attributes (tables) and content (functions, strings, numbers).
-- @treturn string The generated HTML tag string.
-- @usage
-- -- Moonscript example
-- html = require"html"
-- with html
--   div = .div class: "container", "Hello, world!"
--   -- div will be '<div class="container">Hello, world!</div>'
--   link = .a href: "https://example.com", "Visit Example"
--   -- link will be '<a href="https://example.com">Visit Example</a>'
--   empty_tag = .br!
--   -- empty_tag will be '<br/>'
--   script_tag = .script src: "path/to/script.js", ""
--   -- script_tag will be '<script src="path/to/script.js"></script>'
--   nested_example = .div(
--     class: "parent"
--     .h1 "Title"
--     .p "Some text with a ", .a href: "#", " link."
--     .ul(
--       .li "Item 1"
--       .li "Item 2"
--     )
--   )
--   -- nested_example will be a multiline string like:
--   -- '<div class="parent">
--   -- <h1>Title</h1>
--   -- <p>Some text with a
--   -- <a href="#">link</a>.</p>
--   -- <ul>
--   -- <li>Item 1</li>
--   -- <li>Item 2</li>
--   -- </ul>
--   -- </div>'
--
-- @usage
-- -- Lua example
-- local html = require("uhttpd_lua.lib.html")
-- local div = html.div({ class = "container" }, "Hello, world!")
-- -- div will be '<div class="container">Hello, world!</div>'
-- local link = html.a({ href = "https://example.com" }, "Visit Example")
-- -- link will be '<a href="https://example.com">Visit Example</a>'
-- local empty_tag = html.br({})
-- -- empty_tag will be '<br/>'
-- local script_tag = html.script({"", src = "path/to/script.js" })
-- -- script_tag will be '<script src="path/to/script.js"></script>'
---
html = __index: (k) => (...) ->
  ct, props = {}, {}
  for i = 1, select '#', ...
    arg = select i, ...
    switch type arg
      when "table"
        while #arg > 0
          ct[#ct+1] = remove arg, 1
        props[#props+1] = (_v == true and " #{_k}" or " #{_k}=\"#{_v}\"") for _k, _v in pairs arg
      when "function"
        ct[#ct+1] = arg!
      when "string", "number"
        ct[#ct+1] = arg
  #ct == 0 and "<#{k}#{concat props}/>" or "<#{k}#{concat props}>#{concat ct, '\n'}</#{k}>"
setmetatable html, html

pcall require, "moon"
if arg[0] == debug.getinfo(1, 'S').short_src
  with html
    assert '<div class="container">Hello, world!</div>' == .div class: "container", "Hello, world!"
    assert '<a href="https://example.com">Visit Example</a>' == .a href: "https://example.com", "Visit Example"
    assert '<br/>' == .br!
    assert '<script src="path/to/script.js"></script>' == .script src: "path/to/script.js", ""
    assert .div(
      class: "parent"
      .h1 "Title"
      .p "Some text with a ", .a href: "#", " link."
      .ul(
        .li "Item 1"
        .li "Item 2"
      )
    ) == '<div class="parent"><h1>Title</h1>\n<p>Some text with a \n<a href="#"> link.</a></p>\n<ul><li>Item 1</li>\n<li>Item 2</li></ul></div>'

html
