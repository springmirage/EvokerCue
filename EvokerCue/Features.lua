local _, EC = ...

-- Release policy only: never persisted to SavedVariables. Restore each feature
-- here after validation; original modules, aliases and plan data remain intact.
EC.Features = { ball = false, dreamLoom = false }
function EC.Features:SkillEnabled(key)
    return key ~= "BALL" or self.ball == true
end
function EC.Features:DreamLoomEnabled()
    return self.dreamLoom == true and self.ball == true
end
