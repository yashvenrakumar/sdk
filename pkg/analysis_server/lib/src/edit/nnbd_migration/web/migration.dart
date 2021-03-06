// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html';

import 'package:analysis_server/src/edit/nnbd_migration/web/edit_details.dart';
import 'package:analysis_server/src/edit/nnbd_migration/web/file_details.dart';
import 'package:analysis_server/src/edit/nnbd_migration/web/navigation_tree.dart';
import 'package:path/path.dart' as _p;

import 'highlight_js.dart';

// TODO(devoncarew): Fix the issue where we can't load source maps.

// TODO(devoncarew): Include a favicon.

void main() {
  document.addEventListener('DOMContentLoaded', (event) {
    String path = window.location.pathname;
    int offset = getOffset(window.location.href);
    int lineNumber = getLine(window.location.href);
    loadNavigationTree();
    if (path != '/' && path != rootPath) {
      // TODO(srawlins): replaceState?
      loadFile(path, offset, lineNumber, true, callback: () {
        pushState(path, offset, lineNumber);
      });
    }

    final applyMigrationButton = document.querySelector('.apply-migration');
    applyMigrationButton.onClick.listen((event) {
      doPost('/apply-migration').then((xhr) {
        document.body.classes
          ..remove('proposed')
          ..add('applied');
      }).catchError((e, st) {
        logError('apply migration error: $e', st);

        window.alert('Could not apply migration ($e).');
      });
    });
  });

  window.addEventListener('popstate', (event) {
    String path = window.location.pathname;
    int offset = getOffset(window.location.href);
    int lineNumber = getLine(window.location.href);
    if (path.length > 1) {
      loadFile(path, offset, lineNumber, false);
    } else {
      // Blank out the page, for the index screen.
      writeCodeAndRegions(path, FileDetails.empty(), true);
      updatePage('&nbsp;', null);
    }
  });
}

String get rootPath => querySelector('.root').text.trim();

void addArrowClickHandler(Element arrow) {
  Element childList =
      (arrow.parentNode as Element).querySelector(':scope > ul');
  // Animating height from "auto" to "0" is not supported by CSS [1], so all we
  // have are hacks. The `* 2` allows for events in which the list grows in
  // height when resized, with additional text wrapping.
  // [1] https://css-tricks.com/using-css-transitions-auto-dimensions/
  childList.style.maxHeight = '${childList.offsetHeight * 2}px';
  arrow.onClick.listen((MouseEvent event) {
    if (!childList.classes.contains('collapsed')) {
      childList.classes.add('collapsed');
      arrow.classes.add('collapsed');
    } else {
      childList.classes.remove('collapsed');
      arrow.classes.remove('collapsed');
    }
  });
}

void addClickHandlers(String selector, bool clearEditDetails) {
  Element parentElement = document.querySelector(selector);

  // Add navigation handlers for navigation links in the source code.
  List<Element> navLinks = parentElement.querySelectorAll('.nav-link');
  navLinks.forEach((link) {
    link.onClick.listen((event) {
      Element tableElement = document.querySelector('table[data-path]');
      String parentPath = tableElement.dataset['path'];
      handleNavLinkClick(event, clearEditDetails, relativeTo: parentPath);
    });
  });

  List<Element> regions = parentElement.querySelectorAll('.region');
  if (regions.isNotEmpty) {
    Element table = parentElement.querySelector('table[data-path]');
    String path = table.dataset['path'];
    regions.forEach((Element anchor) {
      anchor.onClick.listen((event) {
        int offset = int.parse(anchor.dataset['offset']);
        loadAndPopulateEditDetails(path, offset);
      });
    });
  }

  List<Element> postLinks = parentElement.querySelectorAll('.post-link');
  postLinks.forEach((link) {
    link.onClick.listen(handlePostLinkClick);
  });
}

Future<HttpRequest> doPost(String path) => HttpRequest.request(
      path,
      method: 'POST',
      requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'},
    ).then((HttpRequest xhr) {
      if (xhr.status == 200) {
        // Request OK.
        return xhr;
      } else {
        throw 'Request failed; status of ${xhr.status}';
      }
    });

int getLine(String location) {
  String str = Uri.parse(location).queryParameters['line'];
  return str == null ? null : int.tryParse(str);
}

int getOffset(String location) {
  String str = Uri.parse(location).queryParameters['offset'];
  return str == null ? null : int.tryParse(str);
}

void handleNavLinkClick(
  MouseEvent event,
  bool clearEditDetails, {
  String relativeTo,
}) {
  Element target = event.currentTarget;

  String location = target.getAttribute('href');
  String path = location;
  if (path.contains('?')) {
    path = path.substring(0, path.indexOf('?'));
  }
  // Fix-up the path - it might be relative.
  if (relativeTo != null) {
    path = _p.normalize(_p.join(_p.dirname(relativeTo), path));
  }

  int offset = getOffset(location);
  int lineNumber = getLine(location);

  if (offset != null) {
    navigate(path, offset, lineNumber, clearEditDetails, callback: () {
      pushState(path, offset, lineNumber);
    });
  } else {
    navigate(path, null, null, clearEditDetails, callback: () {
      pushState(path, null, null);
    });
  }
  event.preventDefault();
}

void handlePostLinkClick(MouseEvent event) async {
  String path = (event.currentTarget as Element).getAttribute('href');

  // Don't navigate on link click.
  event.preventDefault();

  document.body.classes.add('rerunning');

  try {
    // Directing the server to produce an edit; request it, then do work with the
    // response.
    await doPost(path);
    (document.window.location as Location).reload();
  } catch (e, st) {
    logError('handlePostLinkClick: $e', st);

    window.alert('Could not load $path ($e).');
  } finally {
    document.body.classes.remove('rerunning');
  }
}

void highlightAllCode() {
  document.querySelectorAll('.code').forEach((Element block) {
    hljs.highlightBlock(block);
  });
}

/// Load the explanation for [region], into the ".panel-content" div.
void loadAndPopulateEditDetails(String path, int offset) {
  // Request the region, then do work with the response.
  HttpRequest.request(
    '$path?region=region&offset=$offset',
    requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'},
  ).then((HttpRequest xhr) {
    if (xhr.status == 200) {
      var response = EditDetails.fromJson(jsonDecode(xhr.responseText));
      populateEditDetails(response);
      addClickHandlers('.edit-panel .panel-content', false);
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadRegionExplanation: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

/// Load the file at [path] from the server, optionally scrolling [offset] into
/// view.
void loadFile(
  String path,
  int offset,
  int line,
  bool clearEditDetails, {
  VoidCallback callback,
}) {
  // Handle the case where we're requesting a directory.
  if (!path.endsWith('.dart')) {
    writeCodeAndRegions(path, FileDetails.empty(), clearEditDetails);
    updatePage(path);
    if (callback != null) {
      callback();
    }

    return;
  }

  // Navigating to another file; request it, then do work with the response.
  HttpRequest.request(
    path.contains('?') ? '$path&inline=true' : '$path?inline=true',
    requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'},
  ).then((HttpRequest xhr) {
    if (xhr.status == 200) {
      Map<String, dynamic> response = jsonDecode(xhr.responseText);
      writeCodeAndRegions(
          path, FileDetails.fromJson(response), clearEditDetails);
      maybeScrollToAndHighlight(offset, line);
      String filePathPart =
          path.contains('?') ? path.substring(0, path.indexOf('?')) : path;
      updatePage(filePathPart, offset);
      if (callback != null) {
        callback();
      }
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadFile: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

/// Load the navigation tree into the ".nav-tree" div.
void loadNavigationTree() {
  String path = '/_preview/navigationTree.json';

  // Request the navigation tree, then do work with the response.
  HttpRequest.request(
    path,
    requestHeaders: {'Content-Type': 'application/json; charset=UTF-8'},
  ).then((HttpRequest xhr) {
    if (xhr.status == 200) {
      dynamic response = jsonDecode(xhr.responseText);
      var navTree = document.querySelector('.nav-tree');
      navTree.innerHtml = '';
      writeNavigationSubtree(
          navTree, NavigationTreeNode.listFromJson(response));
    } else {
      window.alert('Request failed; status of ${xhr.status}');
    }
  }).catchError((e, st) {
    logError('loadNavigationTree: $e', st);

    window.alert('Could not load $path ($e).');
  });
}

void logError(e, st) {
  window.console.error('$e');
  window.console.error('$st');
}

final Element headerPanel = document.querySelector('header');
final Element footerPanel = document.querySelector('footer');

/// Scroll an element into view if it is not visible.
void maybeScrollIntoView(Element element) {
  Rectangle rect = element.getBoundingClientRect();
  // A line of text in the code view is 14px high. Including it here means we
  // only choose to _not_ scroll a line of code into view if the entire line is
  // visible.
  var lineHeight = 14;
  var visibleCeiling = headerPanel.offsetHeight + lineHeight;
  var visibleFloor =
      window.innerHeight - (footerPanel.offsetHeight + lineHeight);
  if (rect.bottom > visibleFloor) {
    element.scrollIntoView();
  } else if (rect.top < visibleCeiling) {
    element.scrollIntoView();
  }
}

/// Scroll target with id [offset] into view if it is not currently in view.
///
/// If [offset] is null, instead scroll the "unit-name" header, at the top of
/// the page, into view.
///
/// Also add the "target" class, highlighting the target. Also add the
/// "highlight" class to the entire line on which the target lies.
void maybeScrollToAndHighlight(int offset, int lineNumber) {
  Element target;
  Element line;

  if (offset != null) {
    target = document.getElementById('o$offset');
    line = document.querySelector('.line-$lineNumber');
    if (target != null) {
      maybeScrollIntoView(target);
      target.classes.add('target');
    } else if (line != null) {
      // If the target doesn't exist, but the line does, scroll that into view
      // instead.
      maybeScrollIntoView(line.parent);
    }
    if (line != null) {
      (line.parentNode as Element).classes.add('highlight');
    }
  } else {
    // If no offset is given, this is likely a navigation link, and we need to
    // scroll back to the top of the page.
    maybeScrollIntoView(unitName);
  }
}

/// Navigate to [path] and optionally scroll [offset] into view.
///
/// If [callback] is present, it will be called after the server response has
/// been processed, and the content has been updated on the page.
void navigate(
  String path,
  int offset,
  int lineNumber,
  bool clearEditDetails, {
  VoidCallback callback,
}) {
  int currentOffset = getOffset(window.location.href);
  int currentLineNumber = getLine(window.location.href);
  removeHighlight(currentOffset, currentLineNumber);
  if (path == window.location.pathname) {
    // Navigating to same file; just scroll into view.
    maybeScrollToAndHighlight(offset, lineNumber);
    if (callback != null) {
      callback();
    }
  } else {
    loadFile(path, offset, lineNumber, clearEditDetails, callback: callback);
  }
}

String pluralize(int count, String single, {String multiple}) {
  return count == 1 ? single : (multiple ?? '${single}s');
}

final Element editPanel = document.querySelector('.edit-panel .panel-content');

void populateEditDetails([EditDetails response]) {
  editPanel.innerHtml = '';

  if (response == null) {
    // Clear out any current edit details.
    editPanel.append(ParagraphElement()
      ..text = 'See details about a proposed edit.'
      ..classes = ['placeholder']);
    return;
  }

  String filePath = response.path;
  String parentDirectory = _p.dirname(filePath);

  // 'Changed ... at foo.dart:12.'
  String explanationMessage = response.explanation;
  String relPath = _p.relative(filePath, from: rootPath);
  int line = response.line;
  Element explanation = editPanel.append(document.createElement('p'));
  explanation.append(Text('$explanationMessage at $relPath:$line.'));
  _populateEditTraces(response, editPanel, parentDirectory);
  _populateEditLinks(response, editPanel);
  _populateEditRationale(response, editPanel, parentDirectory);
}

final Element editListElement =
    document.querySelector('.edit-list .panel-content');

/// Write the contents of the Edit List, from JSON data [editListData].
void populateProposedEdits(
    String path, List<EditListItem> edits, bool clearEditDetails) {
  editListElement.innerHtml = '';

  Element p = editListElement.append(document.createElement('p'));
  int editCount = edits.length;
  if (editCount == 0) {
    p.append(Text('No proposed edits'));
  } else {
    p.append(Text('$editCount proposed ${pluralize(editCount, 'edit')}:'));
  }

  Element list = editListElement.append(document.createElement('ul'));
  for (var edit in edits) {
    Element item = list.append(document.createElement('li'));
    item.classes.add('edit');
    AnchorElement anchor = item.append(document.createElement('a'));
    anchor.classes.add('edit-link');
    int offset = edit.offset;
    anchor.dataset['offset'] = '$offset';
    int line = edit.line;
    anchor.dataset['line'] = '$line';
    anchor.append(Text('line $line'));
    anchor.onClick.listen((MouseEvent event) {
      navigate(window.location.pathname, offset, line, true, callback: () {
        pushState(window.location.pathname, offset, line);
      });
      loadAndPopulateEditDetails(path, offset);
    });
    item.append(Text(': ${edit.explanation}'));
  }

  if (clearEditDetails) {
    populateEditDetails();
  }
}

void pushState(String path, int offset, int line) {
  Uri uri = Uri.parse('${window.location.origin}$path');

  Map<String, dynamic> params = {};
  if (offset != null) params['offset'] = '$offset';
  if (line != null) params['line'] = '$line';

  uri = uri.replace(queryParameters: params.isEmpty ? null : params);
  window.history.pushState({}, '', uri.toString());
}

/// If [path] lies within [root], return the relative path of [path] from [root].
/// Otherwise, return [path].
String relativePath(String path) {
  var root = querySelector('.root').text + '/';
  if (path.startsWith(root)) {
    return path.substring(root.length);
  } else {
    return path;
  }
}

/// Remove highlighting from [offset].
void removeHighlight(int offset, int lineNumber) {
  if (offset != null) {
    var anchor = document.getElementById('o$offset');
    if (anchor != null) {
      anchor.classes.remove('target');
    }
  }
  if (lineNumber != null) {
    var line = document.querySelector('.line-$lineNumber');
    if (line != null) {
      line.parent.classes.remove('highlight');
    }
  }
}

final Element unitName = document.querySelector('#unit-name');

/// Update the heading and navigation links.
///
/// Call this after updating page content on a navigation.
void updatePage(String path, [int offset]) {
  path = relativePath(path);
  // Update page heading.
  unitName.text = path;
  // Update navigation styles.
  document.querySelectorAll('.nav-panel .nav-link').forEach((Element link) {
    var name = link.dataset['name'];
    if (name == path) {
      link.classes.add('selected-file');
    } else {
      link.classes.remove('selected-file');
    }
  });
}

/// Load data from [data] into the .code and the .regions divs.
void writeCodeAndRegions(String path, FileDetails data, bool clearEditDetails) {
  Element regionsElement = document.querySelector('.regions');
  Element codeElement = document.querySelector('.code');

  _PermissiveNodeValidator.setInnerHtml(regionsElement, data.regions);
  _PermissiveNodeValidator.setInnerHtml(codeElement, data.navigationContent);
  populateProposedEdits(path, data.edits, clearEditDetails);

  highlightAllCode();
  addClickHandlers('.code', true);
  addClickHandlers('.regions', true);
}

void writeNavigationSubtree(
    Element parentElement, List<NavigationTreeNode> tree) {
  Element ul = parentElement.append(document.createElement('ul'));
  for (var entity in tree) {
    Element li = ul.append(document.createElement('li'));
    if (entity.type == NavigationTreeNodeType.directory) {
      li.classes.add('dir');
      Element arrow = li.append(document.createElement('span'));
      arrow.classes.add('arrow');
      arrow.innerHtml = '&#x25BC;';
      Element icon = li.append(document.createElement('span'));
      icon.innerHtml = '&#x1F4C1;';
      li.append(Text(entity.name));
      writeNavigationSubtree(li, entity.subtree);
      addArrowClickHandler(arrow);
    } else {
      li.innerHtml = '&#x1F4C4;';
      Element a = li.append(document.createElement('a'));
      a.classes.add('nav-link');
      a.dataset['name'] = entity.path;
      a.setAttribute('href', entity.href);
      a.append(Text(entity.name));
      a.onClick.listen((MouseEvent event) => handleNavLinkClick(event, true));
      int editCount = entity.editCount;
      if (editCount > 0) {
        Element editsBadge = li.append(document.createElement('span'));
        editsBadge.classes.add('edit-count');
        editsBadge.setAttribute(
            'title', '$editCount ${pluralize(editCount, 'edit')}');
        editsBadge.append(Text(editCount.toString()));
      }
    }
  }
}

AnchorElement _aElementForLink(TargetLink link, String parentDirectory) {
  int targetLine = link.line;
  AnchorElement a = document.createElement('a');
  a.append(Text('${link.path}:$targetLine'));

  String relLink = link.href;
  String fullPath = _p.normalize(_p.join(parentDirectory, relLink));

  a.setAttribute('href', fullPath);
  a.classes.add('nav-link');
  return a;
}

void _populateEditLinks(EditDetails response, Element editPanel) {
  if (response.edits != null) {
    for (var edit in response.edits) {
      Element editParagraph = editPanel.append(document.createElement('p'));
      Element a = editParagraph.append(document.createElement('a'));
      a.append(Text(edit.description));
      a.setAttribute('href', edit.href);
      a.classes = ['post-link', 'before-apply'];
    }
  }
}

void _populateEditRationale(
    EditDetails response, Element editPanel, String parentDirectory) {
  int detailCount = response.details.length;
  if (detailCount == 0) {
    // Having 0 details is not necessarily an expected possibility, but handling
    // the possibility prevents awkward text, "for 0 reasons:".
  } else {
    editPanel
        .append(ParagraphElement()..text = 'Edit rationale (experimental):');

    Element detailList = editPanel.append(document.createElement('ul'));
    for (var detail in response.details) {
      var detailItem = detailList.append(document.createElement('li'));
      detailItem.append(Text(detail.description));
      var link = detail.link;
      if (link != null) {
        detailItem.append(Text(' ('));
        detailItem.append(_aElementForLink(link, parentDirectory));
        detailItem.append(Text(')'));
      }
    }
  }
}

void _populateEditTraces(
    EditDetails response, Element editPanel, String parentDirectory) {
  for (var trace in response.traces) {
    var traceParagraph =
        editPanel.append(document.createElement('p')..classes = ['trace']);
    traceParagraph.append(document.createElement('span')
      ..classes = ['type-description']
      ..append(Text(trace.description)));
    traceParagraph.append(Text(':'));
    var ul = traceParagraph
        .append(document.createElement('ul')..classes = ['trace']);
    for (var entry in trace.entries) {
      var li = ul.append(document.createElement('li')..innerHtml = '&#x274F; ');
      li.append(document.createElement('span')
        ..classes = ['function']
        ..append(Text(entry.function ?? 'unknown')));
      var link = entry.link;
      if (link != null) {
        li.append(Text(' ('));
        li.append(_aElementForLink(link, parentDirectory));
        li.append(Text(')'));
      }
      li.append(Text(': '));
      li.append(Text(entry.description));
    }
  }
}

class _PermissiveNodeValidator implements NodeValidator {
  static _PermissiveNodeValidator instance = _PermissiveNodeValidator();

  @override
  bool allowsAttribute(Element element, String attributeName, String value) {
    return true;
  }

  @override
  bool allowsElement(Element element) {
    return true;
  }

  static void setInnerHtml(Element element, String html) {
    element.setInnerHtml(html, validator: instance);
  }
}
