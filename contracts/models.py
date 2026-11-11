"""Shared v1 contract. A imports these models or contracts/openapi.json; do not fork them."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)


class SourceRef(BaseModel):
    material_id: str
    chunk_id: str
    page: int
    quote: str
    start: int
    end: int


class ErrorEnvelope(BaseModel):
    error: dict


class Job(BaseModel):
    job_id: str
    status: Literal["queued", "running", "succeeded", "failed"]
    progress: int
    result_ref: dict | None = None
    error_code: str | None = None
    error_message: str | None = None
    retryable: bool
    attempts: int
    created_at: str
    updated_at: str


class MaterialCorrection(Input):
    chunk_id: str
    text: str = Field(min_length=1, max_length=12000)


class GraphExtract(Input):
    material_ids: list[str] = Field(min_length=1, max_length=20)


class ConceptCreate(Input):
    title: str = Field(min_length=1, max_length=100)
    description: str = Field(default="", max_length=5000)
    source_refs: list[SourceRef] = Field(min_length=1, max_length=30)


class ConceptPatch(Input):
    title: str | None = Field(default=None, min_length=1, max_length=100)
    description: str | None = Field(default=None, max_length=5000)
    source_refs: list[SourceRef] | None = Field(default=None, min_length=1, max_length=30)


class EdgeCreate(Input):
    from_id: str
    to_id: str
    type: Literal["prerequisite", "related"]


class EdgePatch(Input):
    from_id: str | None = None
    to_id: str | None = None
    type: Literal["prerequisite", "related"] | None = None


class Search(Input):
    query: str = Field(min_length=1, max_length=2000)
    limit: int = Field(default=5, ge=1, le=20)


class Ask(Input):
    question: str = Field(min_length=1, max_length=2000)
    mode: Literal["explain", "socratic", "hint", "solution"] = "explain"
    hint_level: int = Field(default=1, ge=1, le=3)
    question_id: str | None = None
    practice_session_id: str | None = None


class QuestionSourceView(Input):
    practice_session_id: str


class LessonGenerate(Input):
    title: str = Field(default="知识点课程", min_length=1, max_length=100)
    concept_ids: list[str] = Field(min_length=1, max_length=12)


class Position(Input):
    page_id: str
    segment_id: str
    offset_seconds: float = Field(default=0, ge=0, le=86400)
    source_task_id: str | None = Field(default=None, max_length=200)


class QuestionCreate(Input):
    kind: Literal["single_choice", "numeric", "short_answer", "cloze"]
    prompt: str = Field(min_length=1, max_length=6000)
    options: dict[str, str] = Field(default_factory=dict)
    answer: str = Field(min_length=1, max_length=3000)
    accepted_answers: list[str] = Field(default_factory=list, max_length=30)
    rubric: list[str] = Field(default_factory=list, max_length=20)
    concept_ids: list[str] = Field(min_length=1, max_length=20)
    source_refs: list[SourceRef] = Field(min_length=1, max_length=20)
    explanation: str = Field(min_length=1, max_length=6000)
    initial_difficulty: Literal["easy", "medium", "hard"] = "medium"
    tolerance: float = Field(default=0.000001, ge=0, le=0.1)


class BlueprintSlot(Input):
    concept_id: str
    count: int = Field(ge=1, le=20)
    kind: Literal["cloze", "numeric"] = "cloze"
    difficulty: Literal["easy", "medium", "hard"] = "medium"
    points: float = Field(default=10, gt=0, le=100)


class BlueprintCreate(Input):
    title: str = Field(default="仿真练习卷", min_length=1, max_length=100)
    slots: list[BlueprintSlot] = Field(min_length=1, max_length=20)
    duration_minutes: int = Field(default=45, ge=1, le=300)


class ExamAnalyze(Input):
    material_id: str


class ExamGenerate(Input):
    blueprint_id: str
    seed: int = Field(default=42, ge=0, le=2147483647)


class MistakeCapture(Input):
    material_id: str
    page: int = Field(default=1, ge=1)
    original_answer: str = Field(default="", max_length=6000)
    concept_ids: list[str] = Field(default_factory=list, max_length=20)


class MistakeConfirm(Input):
    question: QuestionCreate
    error_cause: str = Field(default="待诊断", max_length=1000)


class MistakeTranscription(Input):
    text: str = Field(min_length=1, max_length=6000)


class MistakeDiagnosis(Input):
    error_cause: str = Field(min_length=1, max_length=1000)


class VariantGenerate(Input):
    count: int = Field(default=2, ge=1, le=10)
    seed: int = Field(default=42, ge=0, le=2147483647)


class AttemptSubmit(Input):
    question_id: str
    answer: str = Field(max_length=6000)
    practice_session_id: str
    source_task_id: str | None = Field(default=None, max_length=200)
    review_id: str | None = None
    exam_id: str | None = None


class ManualGrade(Input):
    score: float = Field(ge=0, le=1)
    rationale: str = Field(min_length=10, max_length=6000)


class ReviewRate(Input):
    attempt_id: str
    quality: int = Field(ge=0, le=5)


class Candidate(BaseModel):
    candidate_id: str
    type: Literal["concept", "lesson", "question", "review"]
    target_id: str
    estimated_minutes: int
    reason: str
    suggested_due_at: str


class LearningEvent(BaseModel):
    event_id: str
    user_id: str
    course_id: str
    source_task_id: str | None
    event_type: Literal["practice_submitted", "practice_graded", "review_completed"]
    result: dict
    occurred_at: str


class LearningSnapshot(BaseModel):
    user_id: str
    course_id: str
    state_version: int
    concept_states: list[dict]
    candidates: list[Candidate]
    generated_at: str


class Output(BaseModel):
    model_config = ConfigDict(extra="allow")


class ContentElement(Output):
    element_id: str
    type: Literal["text"]
    text: str
    source_refs: list[SourceRef]


class NarrationSegment(Output):
    segment_id: str
    text: str
    highlight_element_ids: list[str]


class LessonPage(Output):
    page_id: str
    title: str
    concept_ids: list[str]
    elements: list[ContentElement]
    narration_segments: list[NarrationSegment]


class GenerationWarning(Output):
    concept_id: str
    code: str
    message: str


class Lesson(Output):
    lesson_id: str
    title: str
    outline: list[dict]
    pages: list[LessonPage]
    generation_method: str
    generation_warnings: list[GenerationWarning] = Field(default_factory=list)
    created_at: str


class AttemptResult(Output):
    attempt_id: str
    question_id: str
    concept_ids: list[str]
    status: Literal["submitted", "pending_review", "graded"]
    score: float | None
    hint_records: list[dict]
    solution_viewed: bool
    evidence_exclusion_reason: str | None = None
    grading_rationale: str | None = None
    source_task_id: str | None = None


class EventPage(BaseModel):
    items: list[LearningEvent]
    next_cursor: str
    has_more: bool
