{$, jQuery, View} = require "atom-space-pen-views"
{TreeView} = require "./tree-view"
XQUtils = require './xquery-helper'
request = require 'request'
path = require 'path'
fs = require 'fs'
tmp = require 'tmp'
mkdirp = require 'mkdirp'
{CompositeDisposable} = require 'atom'
mime = require 'mime'

module.exports =
    class EXistTreeView extends View

        @content: ->
            @div class: "existdb-tree"

        @tmpDir: null

        initialize: (@state, @config) ->
            mime.define({
                "application/xquery": ["xq", "xql", "xquery", "xqm"]
            })

            atom.workspace.observeTextEditors((editor) =>
                buffer = editor.getBuffer()
                p = buffer.getPath()
                if /^\/db\/.*/.test(p) and not buffer._remote?
                    console.log("Reopen %s from database", p)
                    editor.destroy()
                    @open(path: p, buffer)
            )

            @disposables = new CompositeDisposable()
            @treeView = new TreeView

            @treeView.onSelect ({node, item}) ->
                console.log("Selected %o", item)

            @append(@treeView)

            atom.config.observe 'existdb-tree-view.scrollAnimation', (enabled) =>
                @animationDuration = if enabled then 300 else 0

            @treeView.width(@state.width) if @state?.width
            @toggle() if @state?.show

        serialize: ->
            width: @treeView.width()
            show: @hasParent()

        populate: ->
            root = {
                label: "db",
                path: "/db",
                icon: "icon-database",
                children: [],
                loaded: true
            }
            @treeView.setRoot(root, false)
            @load(root)

        load: (item, callback) =>
            self = this
            editor = atom.workspace.getActiveTextEditor()
            url = @config.getConfig(editor).server +
                "/apps/atom-editor/browse.xql?root=" + item.path
            options =
                uri: url
                method: "GET"
                json: true
                auth:
                    user: @config.getConfig(editor).user
                    pass: @config.getConfig(editor).password || ""
                    sendImmediately: true
            request(
                options,
                (error, response, body) ->
                    if error? or response.statusCode != 200
                        atom.notifications.addError("Failed to load database contents", detail: if response? then response.statusMessage else error)
                    else
                        item.view.setChildren(body)
                        for child in body
                            child.view.onSelect(self.onSelect)
                        callback() if callback
            )

        open: (resource, onOpen) =>
            pane = atom.workspace.paneForURI(resource.path)
            if pane?
                pane.activateItemForURI(resource.path)
                onOpen?(atom.workspace.getActiveTextEditor())
                return

            self = this
            editor = atom.workspace.getActiveTextEditor()
            url = @config.getConfig(editor).server + "/apps/atom-editor/load.xql?path=" + resource.path
            tmpDir = @getTempDir(resource.path)
            tmpFile = path.join(tmpDir, path.basename(resource.path))
            console.log("Downloading %s to %s", resource.path, tmpFile)
            stream = fs.createWriteStream(tmpFile)
            options =
                uri: url
                method: "GET"
                auth:
                    user: @config.getConfig(editor).user
                    pass: @config.getConfig(editor).password || ""
                    sendImmediately: true
            contentType = null
            request(options)
                .on("response", (response) ->
                    contentType = response.headers["content-type"]
                )
                .on("error", (err) ->
                    atom.notifications.addError("Failed to download #{resource.path}", detail: err)
                )
                .on("end", () ->
                    promise = atom.workspace.open(null)
                    promise.then((newEditor) ->
                        buffer = newEditor.getBuffer()
                        buffer.getPath = () -> resource.path
                        buffer.setPath(tmpFile)
                        buffer.loadSync()
                        resource.editor = newEditor
                        buffer._remote = resource
                        onDidSave = buffer.onDidSave((ev) ->
                            self.save(tmpFile, resource, contentType)
                        )
                        onDidDestroy = buffer.onDidDestroy((ev) ->
                            self.disposables.remove(onDidSave)
                            self.disposables.remove(onDidDestroy)
                            onDidDestroy.dispose()
                            onDidSave.dispose()
                            fs.unlink(tmpFile)
                        )
                        self.disposables.add(onDidSave)
                        self.disposables.add(onDidDestroy)
                        XQUtils.xqlint(newEditor)
                        onOpen?(newEditor)
                    )
                )
                .pipe(stream)

        getOpenEditor: (resource) ->
            for editor in atom.workspace.getTextEditors()
                if editor.getBuffer()._remote?.path == resource.path
                    return editor
            return null

        save: (file, resource, contentType) ->
            editor = atom.workspace.getActiveTextEditor()
            url = "#{@config.getConfig(editor).server}/rest/#{resource.path}"
            contentType = mime.lookup(path.extname(file)) unless contentType
            console.log("Saving %s using content type %s", resource.path, contentType)
            options =
                uri: url
                method: "PUT"
                auth:
                    user: @config.getConfig(editor).user
                    pass: @config.getConfig(editor).password || ""
                    sendImmediately: true
                headers:
                    "Content-Type": contentType
            fs.createReadStream(file).pipe(
                request(
                    options,
                    (error, response, body) ->
                        if error?
                            atom.notifications.addError("Failed to upload #{resource.path}", detail: error)
                        else
                            atom.notifications.addSuccess("Uploaded #{resource.path}: #{response.statusCode}.")
                )
            )

        onSelect: ({node, item}) =>
            if not item.loaded
                @load(item, () ->
                    item.loaded = true
                    item.view.toggleClass('collapsed')
                )
            else if item.type == "resource"
                @open(item)

        destroy: ->
            @element.remove()
            @disposables.dispose()
            @tempDir.removeCallback() if @tempDir

        attach: ->
            if (atom.config.get('tree-view.showOnRightSide'))
                @panel = atom.workspace.addLeftPanel(item: this)
            else
                @panel = atom.workspace.addRightPanel(item: this)

        remove: ->
          super
          @panel.destroy()

        # Toggle the visibility of this view
        toggle: ->
          if @hasParent()
            @remove()
          else
            @populate()
            @attach()

        # Show view if hidden
        showView: ->
          if not @hasParent()
            @populate()
            @attach()

        # Hide view if visisble
        hideView: ->
          if @hasParent()
            @remove()

        getTempDir: (uri) ->
            @tempDir = tmp.dirSync({ mode: 0o750, prefix: 'atom-exist_', unsafeCleanup: true }) unless @tempDir
            tmpPath = path.join(@tempDir.name, path.dirname(uri))
            mkdirp.sync(tmpPath)
            return tmpPath
