local connections = require("neogrip.connections")
local notify = require("neogrip.notify")
local resolve = require("neogrip.connections.resolve")

local M = {}

local function command(name, fn, opts)
	vim.api.nvim_create_user_command(name, fn, opts or {})
end

local function connection_names()
	return vim.tbl_map(function(connection)
		return connection.id
	end, connections.all())
end

local function current_connection()
	local connection = resolve.for_buf(0)
	if not connection then
		notify.send("no connection for this buffer", vim.log.levels.WARN)
	end
	return connection
end

function M.setup()
	command("NGripConnections", function()
		local lines = {}
		for _, connection in ipairs(connections.all()) do
			local target = connection.file
				or ("%s:%s/%s"):format(
					connection.host or "?",
					connection.port or "?",
					connection.database or "-"
				)
			lines[#lines + 1] = ("%-18s %-10s %-8s %-40s %s"):format(
				connection.id,
				connection.driver,
				connection.scope,
				target,
				(connection.readonly and "read-only " or "") .. (connection.production and "production" or "")
			)
		end
		if #lines == 0 then
			lines = { "no connections; :NGripInit writes a project file" }
		end
		notify.send(table.concat(lines, "\n"))
	end, { desc = "List the configured database connections" })

	command("NGripWhich", function()
		local connection, reason = resolve.for_buf(0)
		if not connection then
			return notify.send("no connection resolves for this buffer", vim.log.levels.WARN)
		end
		notify.send(("%s [%s] — %s"):format(connection.name, connection.driver, reason))
	end, { desc = "Show which connection this buffer runs against, and why" })

	command("NGripUse", function(args)
		local connection = connections.get(args.args)
		if not connection then
			return notify.send(("no connection %q"):format(args.args), vim.log.levels.ERROR)
		end
		resolve.bind(0, connection.id)
		notify.send(("%s selected for this buffer"):format(connection.name))
	end, {
		nargs = 1,
		complete = connection_names,
		desc = "Use a connection in this buffer",
	})

	command("NGripReload", function()
		connections.reload()
		notify.send("connections reloaded")
	end, { desc = "Re-read the connection files" })

	command("NGripRun", function(args)
		require("neogrip.execute").run({
			bufnr = 0,
			statement = args.args ~= "" and { text = args.args } or nil,
		})
	end, { nargs = "?", desc = "Run a statement (or the one under the cursor)" })

	command("NGripValidate", function()
		require("neogrip.diagnostics").validate({ bufnr = 0, notify = true })
	end, { desc = "Check the statement under the cursor on the server" })

	command("NGripCancel", function()
		require("neogrip.execute").cancel()
	end, { desc = "Cancel the running query" })

	command("NGripDisconnect", function(args)
		local gripd = require("neogrip.gripd")
		if args.bang then
			gripd.disconnect_all()
			return notify.send("disconnected from every database")
		end
		local id = args.args
		if id == "" then
			local connection = current_connection()
			if not connection then
				return
			end
			id = connection.id
		end
		if not gripd.is_connected(id) then
			return notify.send(("%s is not connected"):format(id))
		end
		gripd.disconnect(id)
		notify.send(("disconnected from %s"):format(id))
	end, {
		nargs = "?",
		bang = true,
		complete = connection_names,
		desc = "Stop a connection's gripd (! stops every one)",
	})

	command("NGripNewQuery", function()
		local connection = current_connection()
		if connection then
			require("neogrip.ui.buffer").new_query(connection, "")
		end
	end, { desc = "Open a query buffer against this buffer's connection" })

	command("NGripSchemaReload", function()
		-- Only this buffer's connection: passing nil would clear every connection's catalog.
		local connection = current_connection()
		if not connection then
			return
		end
		require("neogrip.catalog").invalidate(connection)
		notify.send(("%s: cached catalog cleared"):format(connection.name))
	end, { desc = "Clear the cached catalog for this buffer's connection" })

	command("NGripIntrospect", function(args)
		local connection = current_connection()
		if not connection then
			return
		end
		local schema = require("neogrip.catalog")
		-- Sweep the catalog the tree would open on, so what is swept is what a client reads.
		local catalog = schema.catalog_of(connection)
		if args.args ~= "" then
			catalog = args.args
		end

		if args.bang then
			if not schema.introspecting(connection, catalog) then
				return notify.send("nothing is being introspected")
			end
			-- The same cancel the runner uses; it reaches the sweep's own threads too.
			require("neogrip.gripd").request(connection, "cancel", {}, function() end)
			return notify.send("cancelling the introspect")
		end

		notify.send(("introspecting %s%s..."):format(connection.name, catalog and ("/" .. catalog) or ""))
		schema.introspect(connection, catalog, {}, function(summary, err)
			if err then
				return notify.send(("introspect failed: %s"):format(err), vim.log.levels.ERROR)
			end
			notify.send(
				("%s: %d schemas, %d tables, %d columns in %d ms%s%s"):format(
					connection.name,
					summary.schemas,
					summary.tables,
					summary.columns,
					summary.elapsed_ms,
					summary.parallel and "" or " (one connection)",
					summary.partial and " -- definitions incomplete, run it again to finish" or ""
				)
			)
		end)
	end, {
		nargs = "?",
		bang = true,
		desc = "Sweep this buffer's whole database and keep it (! cancels)",
	})

	command("NGripResults", function()
		local grid = require("neogrip.grid")
		local bufnr = grid.current_buf()
		if not bufnr then
			return notify.send("no result yet")
		end
		-- Said here: requery would answer "no rows to materialise", which misleads.
		if grid.is_pending(bufnr) then
			return notify.send("this tab is still running")
		end
		require("neogrip.grid.requery").materialise(bufnr)
	end, { desc = "Query the current result with SQL (DuckDB)" })

	command("NGripCsv", function(args)
		local path = vim.fn.expand(args.args)
		if vim.fn.filereadable(path) == 0 then
			return notify.send(("no such file: %s"):format(path), vim.log.levels.ERROR)
		end
		require("neogrip.grid.requery").query_csv(vim.fs.normalize(vim.fn.fnamemodify(path, ":p")))
	end, { nargs = 1, complete = "file", desc = "Query a CSV file with SQL (DuckDB)" })

	command("NGripExport", function()
		local grid = require("neogrip.grid")
		local bufnr = grid.current_buf()
		if not bufnr then
			return notify.send("no result to export", vim.log.levels.WARN)
		end
		if grid.is_pending(bufnr) then
			return notify.send("this tab is still running", vim.log.levels.WARN)
		end
		require("neogrip.grid.export").pick(bufnr)
	end, { desc = "Export the current result as CSV or JSON" })

	command(
		"NGripKeep",
		function(args)
			local grid = require("neogrip.grid")
			local bufnr = grid.current_buf()
			local state = bufnr and grid.state(bufnr)
			if not state then
				return notify.send("no result to keep", vim.log.levels.WARN)
			end
			local export = require("neogrip.grid.export")
			local path = args.args ~= "" and vim.fn.expand(args.args)
				or (vim.fn.getcwd() .. "/result-" .. os.date("%Y%m%d-%H%M%S") .. ".csv")
			export.page_to_csv(state, path)
			notify.send(("kept as %s"):format(path))
		end,
		{ nargs = "?", complete = "file", desc = "Write the current result where it will not be cleaned up" }
	)

	command("NGripInit", function()
		M.init_project()
	end, { desc = "Create .nvim/database.json for this project" })

	command("NGripDoctor", function()
		require("neogrip.doctor").show()
	end, { desc = "Check gripd, drivers and connections" })
end

--- Write a starter project file only once .gitignore covers it: it holds hosts, user names
--- and kvstore key names.
function M.init_project()
	local root = connections.project_root()
	local path = connections.project_file()
	if vim.fn.filereadable(path) == 1 then
		return notify.send((".nvim/database.json already exists at %s"):format(root))
	end

	vim.system(
		{ "git", "check-ignore", "-q", ".nvim/database.json" },
		{ cwd = root },
		vim.schedule_wrap(function(result)
			-- Only 1 means "not ignored"; other non-zero codes mean this is not a repository.
			if result.code == 1 then
				local answer = vim.fn.confirm(
					".nvim/database.json is not gitignored. Add '.nvim/' to .gitignore?",
					"&Yes\n&No",
					1
				)
				if answer ~= 1 then
					return notify.send("not creating the file: it would be committed", vim.log.levels.WARN)
				end
				local gitignore = root .. "/.gitignore"
				local lines = vim.fn.filereadable(gitignore) == 1 and vim.fn.readfile(gitignore) or {}
				table.insert(lines, ".nvim/")
				vim.fn.writefile(lines, gitignore)
			end

			vim.fn.mkdir(root .. "/.nvim", "p")
			local template = {
				"{",
				'  "version": 2,',
				'  "default": "local",',
				'  "connections": [',
				"    {",
				'      "id": "local",',
				'      "name": "Local Postgres",',
				'      "driver": "postgres",',
				'      "host": "127.0.0.1",',
				'      "port": 5432,',
				'      "database": "app_dev",',
				'      "auth": {',
				'        "type": "password",',
				'        "user": "postgres",',
				'        "password": { "kvstore": "local-postgres" }',
				"      }",
				"    }",
				"  ],",
				'  "bindings": [',
				'    { "glob": "db/migrations/**/*.sql", "connection": "local" }',
				"  ]",
				"}",
			}
			vim.fn.writefile(template, root .. "/" .. ".nvim/database.json")
			connections.reload()
			notify.send(("wrote %s — :KVStore local-postgres stores the password"):format(path))
			vim.cmd(("edit %s"):format(vim.fn.fnameescape(root .. "/.nvim/database.json")))
		end)
	)
end

return M
