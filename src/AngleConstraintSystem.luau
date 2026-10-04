-- Private normalized triangle/vertex sums and positive-angle wheel constraints.
local S = {}
function S.evaluate(alpha, fans, visit, withJacobian)
	local values, rows = {}, {}
	for base = 0, #alpha - 1, 3 do
		visit(3)
		table.insert(values, (alpha[base + 1] + alpha[base + 2] + alpha[base + 3]) / math.pi - 1)
		if withJacobian then
			table.insert(rows, {
				indices = { base + 1, base + 2, base + 3 },
				values = { 1 / math.pi, 1 / math.pi, 1 / math.pi },
			})
		end
	end
	for _, fan in fans do
		local sum = 0
		local row = withJacobian and { indices = {}, values = {} } or nil
		for _, index in fan do
			visit(1)
			sum += alpha[index]
			if row then
				table.insert(row.indices, index)
				table.insert(row.values, 1 / (2 * math.pi))
			end
		end
		table.insert(values, sum / (2 * math.pi) - 1)
		if row then
			table.insert(rows, row)
		end
		local value = 0
		row = withJacobian and { indices = {}, values = {} } or nil
		for _, offset in { 1, 2 } do
			local logarithm = 0
			local indices = {}
			for _, index in fan do
				visit(1)
				local corner = (index - 1) % 3
				local other = index - corner + (corner + offset) % 3
				table.insert(indices, other)
				logarithm += math.log(math.sin(alpha[other]))
			end
			local mean = math.exp(logarithm / #fan)
			local sign = offset == 1 and 1 or -1
			value += sign * mean
			if row then
				for _, index in indices do
					visit(1)
					table.insert(row.indices, index)
					table.insert(
						row.values,
						sign * mean / #fan * math.cos(alpha[index]) / math.sin(alpha[index])
					)
				end
			end
		end
		table.insert(values, value)
		if row then
			table.insert(rows, row)
		end
	end
	return values, rows
end
function S.multiply(rows, x, visit)
	local result = {}
	for i, row in rows do
		local sum = 0
		for k, index in row.indices do
			visit(1)
			sum += row.values[k] * x[index]
		end
		result[i] = sum
	end
	return result
end
function S.transpose(rows, x, n, visit)
	local result = table.create(n, 0)
	for i, row in rows do
		for k, index in row.indices do
			visit(1)
			result[index] += row.values[k] * x[i]
		end
	end
	return result
end
return S
