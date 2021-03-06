# Tag level tweaks --------------------------------------------------------

tweak_anchors <- function(html, only_contents = TRUE) {
  if (only_contents) {
    sections <- xml2::xml_find_all(html, ".//div[@class='contents']//div[@id]")
  } else {
    sections <- xml2::xml_find_all(html, "//div[@id]")
  }

  if (length(sections) == 0)
    return()

  # Update anchors: dot in the anchor breaks scrollspy
  anchor <- sections %>%
    xml2::xml_attr("id") %>%
    gsub(".", "-", ., fixed = TRUE)
  purrr::walk2(sections, anchor, ~ (xml2::xml_attr(.x, "id") <- .y))

  # Update href of toc anchors , use "-" instead "."
  toc_nav <- xml2::xml_find_all(html, ".//div[@id='tocnav']//a")
  hrefs <- toc_nav %>%
    xml2::xml_attr("href") %>%
    gsub(".", "-", ., fixed = TRUE)
  purrr::walk2(toc_nav, hrefs, ~ (xml2::xml_attr(.x, "href") <- .y))

  headings <- xml2::xml_find_first(sections, ".//h1|h2|h3|h4|h5")
  has_heading <- !is.na(xml2::xml_name(headings))

  for (i in seq_along(headings)[has_heading]) {
    # Insert anchor in first element of header
    heading <- headings[[i]]

    xml2::xml_attr(heading, "class") <- "hasAnchor"
    xml2::xml_add_sibling(
      xml2::xml_contents(heading)[[1]],
      "a", href = paste0("#", anchor[[i]]),
      class = "anchor",
      .where = "before"
    )
  }
  invisible()
}

tweak_md_links <- function(html) {
  links <- xml2::xml_find_all(html, ".//a")
  if (length(links) == 0)
    return()

  hrefs <- xml2::xml_attr(links, "href")
  md_exts <- grepl("\\.md$", hrefs)

  if (any(md_exts)) {
    purrr::walk2(
      links[md_exts],
      gsub("\\.md$", ".html", hrefs[md_exts]),
      xml2::xml_set_attr,
      attr = "href"
    )
  }

  invisible()
}

tweak_tables <- function(html) {
  # Ensure all tables have class="table"
  table <- xml2::xml_find_all(html, ".//table")
  xml2::xml_attr(table, "class") <- "table"

  invisible()
}

# Autolinking -------------------------------------------------------------

# Assumes generated with rmarkdown (i.e. knitr + pandoc)
tweak_code <- function(x) {
  stopifnot(inherits(x, "xml_node"))

  # <pre class="sourceCode r">
  x %>%
    xml2::xml_find_all(".//pre[contains(@class, 'r')]") %>%
    purrr::map(tweak_pre_node)

  # Needs to second so have all packages loaded in chunks
  # <code> with no children (just text)
  x %>%
    xml2::xml_find_all(".//code[count(*) = 0]") %>%
    tweak_code_nodeset()


  invisible()
}

tweak_code_nodeset <- function(nodes, ...) {
  text <- nodes %>% xml2::xml_text()
  href <- text %>% purrr::map_chr(href_string, ...)

  has_link <- !is.na(href)

  nodes[has_link] %>%
    xml2::xml_contents() %>%
    xml2::xml_replace("a", href = href[has_link], text[has_link])

  invisible()
}

# Process in order, because attaching a package affects later code chunks
tweak_pre_node <- function(node, ...) {
  # Register attached packages
  text <- node %>% xml2::xml_text()
  expr <- tryCatch(parse(text = text), error = function(e) NULL)
  packages <- extract_package_attach(expr)
  register_attached_packages(packages)

  # Find nodes with class kw and look backward to see if its qualified
  span <- node %>% xml2::xml_find_all(".//span[@class = 'kw']")
  pkg <- span %>% purrr::map_chr(find_qualifier)
  has_pkg <- !is.na(pkg)

  # Extract text and link
  text <- span %>% xml2::xml_text()
  href <- chr_along(text)
  href[has_pkg] <- purrr::map2_chr(text[has_pkg], pkg[has_pkg], href_topic_remote)
  href[!has_pkg] <- purrr::map_chr(text[!has_pkg], href_topic_local)

  has_link <- !is.na(href)

  span[has_link] %>%
    xml2::xml_contents() %>%
    xml2::xml_replace("a", href = href[has_link], text[has_link])

  invisible()
}

find_qualifier <- function(node) {
  prev <- rev(xml2::xml_find_all(node, "./preceding-sibling::node()"))
  if (length(prev) < 2) {
    return(NA_character_)
  }

  colons <- prev[[1]]
  if (xml2::xml_name(colons) != "span" || xml2::xml_text(colons) != "::") {
    return(NA_character_)
  }

  qual <- prev[[2]]
  if (xml2::xml_name(qual) != "text") {
    return(NA_character_)
  }

  rematch::re_match("([[:alnum:]]+)$", xml2::xml_text(qual))[, 2]
}

# File level tweaks --------------------------------------------

tweak_rmarkdown_html <- function(html, input_path) {
  # Automatically link funtion mentions
  tweak_code(html)
  tweak_anchors(html, only_contents = FALSE)
  tweak_md_links(html)

  # Tweak classes of navbar
  toc <- xml2::xml_find_all(html, ".//div[@id='tocnav']//ul")
  xml2::xml_attr(toc, "class") <- "nav nav-pills nav-stacked"

  # Mame sure all images use relative paths
  img <- xml2::xml_find_all(html, "//img")
  src <- xml2::xml_attr(img, "src")
  abs_src <- is_absolute_path(src)
  if (any(abs_src)) {
    purrr::walk2(
      img[abs_src],
      path_rel(src[abs_src], input_path),
      xml2::xml_set_attr,
      attr = "src"
    )
  }

  tweak_tables(html)

  invisible()
}

tweak_homepage_html <- function(html, strip_header = FALSE) {
  badges <- badges_extract(html)
  if (length(badges) > 0) {
    list <- sidebar_section("Dev status", badges)
    list_div <- paste0("<div>", list, "</div>")
    list_html <- list_div %>% xml2::read_html() %>% xml2::xml_find_first(".//div")

    sidebar <- html %>% xml2::xml_find_first(".//div[@id='sidebar']")
    list_html %>%
      xml2::xml_children() %>%
      purrr::walk(~ xml2::xml_add_child(sidebar, .))
  }

  # Always remove dummy page header
  header <- xml2::xml_find_all(html, ".//div[contains(@class, 'page-header')]")
  if (length(header) > 0)
    xml2::xml_remove(header, free = TRUE)

  header <- xml2::xml_find_first(html, ".//h1")
  if (strip_header) {
    xml2::xml_remove(header, free = TRUE)
  } else {
    page_header_text <- paste0("<div class='page-header'>", header, "</div>")
    page_header <- xml2::read_html(page_header_text) %>% xml2::xml_find_first("//div")
    xml2::xml_replace(header, page_header)
  }

  # Fix relative image links
  imgs <- xml2::xml_find_all(html, ".//img")
  urls <- xml2::xml_attr(imgs, "src")
  new_urls <- gsub("^vignettes/", "articles/", urls)
  new_urls <- gsub("^man/figures/", "reference/figures/", new_urls)
  purrr::map2(imgs, new_urls, ~ (xml2::xml_attr(.x, "src") <- .y))

  tweak_tables(html)

  invisible()
}

# Mutates `html`, removing the badge container
badges_extract <- function(html) {
  # First try specially named div; then try first paragraph
  x <- xml2::xml_find_first(html, "//div[@id='badges']")
  if (length(x) == 0) {
    x <- xml2::xml_find_first(html, "//p")
  }

  # No paragraph
  if (length(x) == 0) {
    return(character())
  }

  # No non-whitespace characters outside of tags
  if (xml2::xml_text(x, trim = TRUE) != "") {
    return(character())
  }

  badges <- xml2::xml_children(x)
  if (length(badges) == 0) {
    return(character())
  }

  if (!all(xml2::xml_name(badges) %in% "a")) {
    return(character())
  }

  xml2::xml_remove(x)

  as.character(badges)
}

badges_extract_text <- function(x) {
  xml <- xml2::read_html(x)
  badges_extract(xml)
}

# Update file on disk -----------------------------------------------------

update_html <- function(path, tweak, ...) {
  html <- xml2::read_html(path, encoding = "UTF-8")
  tweak(html, ...)

  xml2::write_html(html, path, format = FALSE)
  path
}

