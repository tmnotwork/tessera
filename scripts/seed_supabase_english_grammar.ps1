# Seed Supabase with 英文法 subject + knowledge + questions from assets
# Prerequisite: Run supabase/apply_schema.sql in Supabase Dashboard SQL Editor first
# Usage: .\scripts\seed_supabase_english_grammar.ps1

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$assetPath = Join-Path $projectRoot "assets"

$base = "https://wnufzrehvhcwclnwxwim.supabase.co/rest/v1"
$h = @{
    "apikey"       = "sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es"
    "Authorization" = "Bearer sb_publishable_6ZOloNwIgIFjF9SKRLGgmA_Yc55g0es"
    "Content-Type"  = "application/json"
    "Prefer"       = "return=representation"
}

Write-Host "1) Get or create subject 英文法..." -ForegroundColor Cyan
$uriSub = $base + "/subjects"
$uriSubQuery = $base + "/subjects?name=eq.%E8%8B%B1%E6%96%87%E6%B3%95`&select=id"
$subjects = Invoke-RestMethod -Uri $uriSubQuery -Headers $h -Method Get
if ($subjects -and $subjects.Count -gt 0) {
    $subjectId = $subjects[0].id
    Write-Host "   Subject id: $subjectId" -ForegroundColor Green
} else {
    $body = '{"name":"英文法","display_order":1}'
    $created = Invoke-RestMethod -Uri $uriSub -Headers $h -Method Post -Body $body
    $subjectId = if ($created -is [Array] -and $created.Count -gt 0) { $created[0].id } else { $created.id }
    Write-Host "   Created subject id: $subjectId" -ForegroundColor Green
}

Write-Host "2) Delete existing 英文法 knowledge and questions..." -ForegroundColor Cyan
$uriKList = $base + "/knowledge?subject_id=eq." + $subjectId + "`&select=id"
$allK = Invoke-RestMethod -Uri $uriKList -Headers $h -Method Get
if ($allK -and $allK.Count -gt 0) {
    foreach ($k in $allK) {
        $uq = $base + "/questions?knowledge_id=eq." + $k.id
        Invoke-WebRequest -Uri $uq -Headers $h -Method Delete -UseBasicParsing | Out-Null
    }
    foreach ($k in $allK) {
        $uk = $base + "/knowledge?id=eq." + $k.id
        Invoke-WebRequest -Uri $uk -Headers $h -Method Delete -UseBasicParsing | Out-Null
    }
    Write-Host "   Deleted $($allK.Count) knowledge rows" -ForegroundColor Gray
}

Write-Host "3) Insert knowledge from assets/knowledge.json..." -ForegroundColor Cyan
$knowledgeJson = Get-Content -Path (Join-Path $assetPath "knowledge.json") -Raw -Encoding UTF8
$knowledgeList = $knowledgeJson | ConvertFrom-Json
$idMap = @{}
$kCount = 0
$uriKnowledge = $base + "/knowledge"
foreach ($raw in $knowledgeList) {
    $topic = if ($raw.topic) { $raw.topic.ToString().Trim() } else { "" }
    $title = $raw.title.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { continue }
    $explanation = if ($raw.explanation) { $raw.explanation.ToString().Trim() } else { $null }
    $assetId = $raw.id.ToString()
    $bodyObj = @{
        subject_id  = $subjectId
        subject     = "英文法"
        unit        = if ($topic) { $topic } else { $null }
        content     = $title
        description = $explanation
    }
    $body = $bodyObj | ConvertTo-Json -Compress
    try {
        $res = Invoke-RestMethod -Uri $uriKnowledge -Headers $h -Method Post -Body $body -ContentType 'application/json'
        $newId = if ($res -is [Array] -and $res.Count -gt 0) { $res[0].id } else { $res.id }
        $idMap[$assetId] = $newId
        $kCount++
    } catch {
        Write-Host "   Error knowledge $assetId : $_" -ForegroundColor Red
    }
}
Write-Host "   Inserted knowledge: $kCount" -ForegroundColor Green

Write-Host "4) Insert questions from assets/questions.json..." -ForegroundColor Cyan
$questionsJson = Get-Content -Path (Join-Path $assetPath "questions.json") -Raw -Encoding UTF8
$questionsList = $questionsJson | ConvertFrom-Json
$qCount = 0
$uriQuestions = $base + "/questions"
foreach ($raw in $questionsList) {
    $questionText = $raw.question.ToString().Trim()
    $correctAnswer = $raw.answer.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($questionText) -or [string]::IsNullOrWhiteSpace($correctAnswer)) { continue }
    $kid = $null
    if ($raw.knowledge_ids -is [Array] -and $raw.knowledge_ids.Count -gt 0) {
        $kid = $raw.knowledge_ids[0].ToString()
    }
    $targetKnowledgeId = $idMap[$kid]
    if (-not $targetKnowledgeId) { continue }
    $explanation = if ($raw.explanation) { $raw.explanation.ToString().Trim() } else { $null }
    $body = @{
        knowledge_id   = $targetKnowledgeId
        question_type  = "text_input"
        question_text  = $questionText
        correct_answer = $correctAnswer
        explanation    = $explanation
    } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Uri $uriQuestions -Headers $h -Method Post -Body $body -ContentType 'application/json' | Out-Null
        $qCount++
    } catch {
        Write-Host "   Error question $($raw.id): $_" -ForegroundColor Red
    }
}
Write-Host "   Inserted questions: $qCount" -ForegroundColor Green

Write-Host "5) Verify..." -ForegroundColor Cyan
$subCheck = Invoke-RestMethod -Uri ($base + "/subjects?select=id,name,display_order") -Headers $h -Method Get
$uriKCount = $base + "/knowledge?subject_id=eq." + $subjectId + "`&select=id"
$kCheck = @(Invoke-RestMethod -Uri $uriKCount -Headers $h -Method Get).Count
$qCheck = @(Invoke-RestMethod -Uri ($base + "/questions?select=id") -Headers $h -Method Get).Count
Write-Host "   subjects: $($subCheck.Count)" -ForegroundColor Green
Write-Host "   knowledge(英文法): $kCheck" -ForegroundColor Green
Write-Host "   questions: $qCheck" -ForegroundColor Green
Write-Host 'Done. Supabase has full English grammar data.' -ForegroundColor Green
