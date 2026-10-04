-- Replace service/root/offset/length placeholders. Supports old and chunked reports.
local function reportText(parent)
	local value = assert(parent:FindFirstChild("VerificationReport"), "Verification report missing")
	if value:IsA("StringValue") then
		return value.Value
	end
	assert(value:IsA("Folder"), "Invalid verification storage")
	local chunks = {}
	for index = 1, value:GetAttribute("Chunks") do
		chunks[index] = value[string.format("Part%04d", index)].Value
	end
	local text = table.concat(chunks)
	assert(#text == value:GetAttribute("Bytes"), "Truncated verification report")
	return text
end
local root = game:GetService("__SERVICE__"):FindFirstChild("__ROOT__")
local text = reportText(assert(root, "Verified tree missing"))
return {
	part = string.sub(text, __OFFSET__, __OFFSET__ + __LENGTH__ - 1),
	bytes = #text,
	state = root:GetAttribute("TestState"),
}
