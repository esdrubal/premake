--
-- configset.lua
--
-- A configuration set manages a collection of fields, which are organized
-- into "blocks". Each block stores a set of field-value pairs, along with
-- a list of terms which indicate the context in which those field values
-- should be applied.
--
-- Configurations use the field definitions to know what fields are available,
-- and the corresponding value types for those fields. Only fields that have
-- been registered via field.new() can be stored.
--
-- Copyright (c) 2012-2014 Jason Perkins and the Premake project
--

	premake.configset = {}
	local configset = premake.configset
	local criteria = premake.criteria


--
-- Create a new configuration set.
--
-- @param parent
--    An optional parent configuration set. If provided, the parent provides
--    a base configuration, which this set will extend.
-- @return
--    A new, empty configuration set.
--

	function configset.new(parent)
		local cset = {}
		cset.parent = parent
		cset.blocks = {}
		cset.current = nil
		cset.compiled = false
		return cset
	end


---
-- Retrieve a value from the configuration set.
--
-- This and the criteria supporting code are the inner loops of the app. Some
-- readability has been sacrificed for overall performance.
--
-- @param cset
--    The configuration set to query.
-- @param field
--    The definition of field to be queried.
-- @param context
--    A list of lowercase context terms to use during the fetch. Only those
--    blocks with terms fully contained by this list will be considered in
--    determining the returned value. Terms should be lower case to make
--    the context filtering case-insensitive.
-- @return
--    The requested value.
---

	function configset.fetch(cset, field, context)
		if not context then
			context = cset.current._criteria.terms
		end

		if premake.field.merges(field) then
			return configset._fetchMerged(cset, field, context)
		else
			return configset._fetchDirect(cset, field, context)
		end
	end


	function configset._fetchDirect(cset, field, filter)
		local abspath = filter.files
		local basedir

		local key = field.name
		local blocks = cset.blocks
		local n = #blocks
		for i = n, 1, -1 do
			local block = blocks[i]
			local value = block[key]

			-- If the filter contains a file path, make it relative to
			-- this block's basedir
			if value and abspath and block._basedir ~= basedir and not cset.compiled then
				basedir = block._basedir
				filter.files = path.getrelative(basedir, abspath)
			end

			if value and (cset.compiled or criteria.matches(block._criteria, filter)) then
				-- If value is an object, return a copy of it so that any
				-- changes later made to it by the caller won't alter the
				-- original value (that was a tough bug to find)
				if type(value) == "table" then
					value = table.deepcopy(value)
				end
				return value
			end
		end

		filter.files = abspath

		if cset.parent then
			return configset._fetchDirect(cset.parent, field, filter)
		end
	end


	function configset._fetchMerged(cset, field, filter)
		local result = {}

		local function remove(patterns)
			for i = 1, #patterns do
				local pattern = patterns[i]

				local j = 1
				while j <= #result do
					local value = result[j]:lower()
					if value:match(pattern) == value then
						result[result[j]] = nil
						table.remove(result, j)
					else
						j = j + 1
					end
				end
			end
		end

		if cset.parent then
			result = configset._fetchMerged(cset.parent, field, filter)
		end

		local abspath = filter.files
		local basedir

		local key = field.name
		local blocks = cset.blocks
		local n = #blocks
		for i = 1, n do
			local block = blocks[i]

			-- If the filter contains a file path, make it relative to
			-- this block's basedir
			if abspath and block._basedir ~= basedir and not cset.compiled then
				basedir = block._basedir
				filter.files = path.getrelative(basedir, abspath)
			end

			if cset.compiled or criteria.matches(block._criteria, filter) then
				if block._removes and block._removes[key] then
					remove(block._removes[key])
				end

				local value = block[key]
				if value then
					result = premake.field.merge(field, result, value)
				end
			end
		end

		filter.files = abspath
		return result
	end



---
-- Create and return a metatable which allows a configuration set to act as a
-- "backing store" for a regular Lua table. Table operations that access a
-- registered field will fetch from or store to the configurations set, while
-- unknown keys are get and set to the table normally.
---

	function configset.metatable(cset)
		return {
			__newindex = function(tbl, key, value)
				local f = premake.field.get(key)
				if f then
					local status, err = configset.store(cset, f, value)
					if err then
						error(err, 2)
					end
				else
					rawset(tbl, key, value)
					return value
				end
			end,
			__index = function(tbl, key)
				local f = premake.field.get(key)
				if f then
					return configset.fetch(cset, f, cset.current._criteria.terms)
				else
					return nil
				end
			end
		}
	end



--
-- Create a new block of configuration field-value pairs, with the provided
-- set of context terms to control their application.
--
-- @param cset
--    The configuration set to hold the new block.
-- @param terms
--    A set of context terms to control the application of values contained
--    in the block.
-- @param basedir
--    An optional base directory; if set, filename filter tests will be made
--    relative to this basis before pattern testing.
-- @return
--    The new configuration data block.
--

	function configset.addblock(cset, terms, basedir)
		local block = {}

		if basedir then
			block._basedir = basedir:lower()
		end

		-- attach a criteria object to the block to control its application
		block._criteria = criteria.new(terms)

		table.insert(cset.blocks, block)
		cset.current = block
		return block
	end



---
-- Add a new field-value pair to the current configuration data block. The
-- data type of the field is taken into account when adding the values:
-- strings are replaced, arrays are merged, etc.
--
-- @param cset
--    The configuration set to hold the new value.
-- @param fieldname
--    The name of the field being set. The field should have already been
--    defined using the api.register() function.
-- @param value
--    The new value for the field.
-- @return
--    If successful, returns true. If an error occurred, returns nil and
--    an error message.
---

	function configset.store(cset, field, value)
		if not cset.current then
			configset.addblock(cset, {})
		end

		local key = field.name
		local current = cset.current

		local status, result = pcall(function ()
			current[key] = premake.field.store(field, current[key], value)
		end)

		if not status then
			if type(result) == "table" then
				result = result.msg
			end
			return nil, result
		end

		return true
	end



--
-- Remove values from a configuration set.
--
-- @param cset
--    The configuration set from which to remove.
-- @param field
--    The field holding the values to be removed.
-- @param values
--    A list of values to be removed.
--

	function configset.remove(cset, field, values)
		-- removes are always processed first; starting a new block here
		-- ensures that they will be processed in the proper order
		local current = cset.current
		configset.addblock(cset, current._criteria.terms, current._basedir)

		-- This needs work; right now it is hardcoded to only work for lists.
		-- To support removing from keyed collections, I first need to figure
		-- out how to move the wildcard():lower() bit into the value
		-- processing call chain (i.e. that should happen somewhere inside of
		-- the field.remove() call). And then I will probably need to add
		-- another accessor to actually do the removing, which right now is
		-- hardcoded inside of _fetchMerged(). Oh, and some of the logic in
		-- api.remove() needs to get pushed down to here (or field).

		values = premake.field.remove(field, {}, values)
		for i, value in ipairs(values) do
			values[i] = path.wildcards(value):lower()
		end

		-- add a list of removed values to the block
		current = cset.current
		current._removes = {}
		current._removes[field.name] = values
	end



--
-- Check to see if a configuration set is empty; that is, it does
-- not contain any configuration blocks.
--
-- @param cset
--    The configuration set to query.
-- @return
--    True if the set does not contain any blocks.
--

	function configset.empty(cset)
		return (#cset.blocks == 0)
	end



--
-- Compiles a new configuration set containing only the blocks which match
-- the specified criteria. Fetches against this compiled configuration set
-- may omit the context argument, resulting in faster fetches against a
-- smaller set of configuration blocks.
--
-- @param cset
--    The configuration set to query.
-- @param filter
--    A list of lowercase context terms to use during the fetch. Only those
--    blocks with terms fully contained by this list will be considered in
--    determining the returned value. Terms should be lower case to make
--    the context filtering case-insensitive.
-- @return
--    A new configuration set containing only the selected blocks, and the
--    "compiled" field set to true.
--

	function configset.compile(cset, filter)
		-- always start with the parent
		local result
		if cset.parent then
			result = configset.compile(cset.parent, filter)
		else
			result = configset.new()
		end

		local blocks = cset.blocks
		local n = #blocks

		local abspath = filter.files
		local basedir

		for i = 1, n do
			local block = blocks[i]

			-- If the filter contains a file path, make it relative to
			-- this block's basedir
			if abspath and block._basedir ~= basedir then
				basedir = block._basedir
				filter.files = path.getrelative(basedir, abspath)
			end

			if criteria.matches(block._criteria, filter) then
				table.insert(result.blocks, block)
			end
		end

		filter.files = abspath

		result.compiled = true
		return result
	end
