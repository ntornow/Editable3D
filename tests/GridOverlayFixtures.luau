-- Split fixture storage stays below Studio's per-ModuleScript source limit.
local fixtures = {}
for _, group in { require(script.Parent.GridOverlayFixturesA), require(script.Parent.GridOverlayFixturesB) } do
	for _, record in group do
		table.insert(fixtures, record)
	end
end
return fixtures
