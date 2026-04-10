# AskGeorge System Architecture

AI-powered failure analysis for ChampionX industrial chemicals. FastAPI + React + Azure.

## Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Backend | Python 3.11, FastAPI, SQLAlchemy, pgvector | `src/` |
| Frontend | React 18, TypeScript | `frontend/` |
| Database | Azure PostgreSQL + pgvector (2000D) | `src/core/database.py` |
| LLM (primary) | Azure OpenAI | `src/core/llm/azure_openai.py` |
| LLM (fallback) | Anthropic Claude via Azure Foundry | `src/core/llm/anthropic_client.py` |
| Blob storage | Azure Blob Storage | Images, documents, reports |
| Auth | Azure AD (OAuth, EasyAuth) | `src/core/auth_config.py` |
| Secrets | Azure Key Vault | `src/core/azure_config.py` |
| Analytics | Power BI (DAX queries via OBO token) | `src/core/powerbi_config.py` |
| Cache | Redis (fallback: in-memory LRU) | `src/core/config.py` |
| CV model | PyTorch (corrosion image classifier) | Singleton, loaded once at startup |

## Request Flow

```
User Query (POST /api/v1/chat)
    |
    v
src/api/routers/chat.py:962  ──────────────────────────────────────
    |                         |                                     |
    v                         v                                     v
[1] FAST PATH            [2] AGENTIC MODE                    [3] LEGACY/RCFA
Product code regex?      USE_AGENTIC_MODE=true?               Default path
    |                         |                                     |
    v                         v                                     v
_fast_product_response   AskGeorgeAgent                       ChatService
O(1) JSON lookup         src/services/agent/agent.py          src/services/conversation_manager.py
No LLM call                  |                                     |
    |                    LLM decides tool calls                     v
    v                         |                               TieredChatOrchestrator
Return immediately       ToolExecutor                         src/services/handlers/orchestrator.py
                         src/services/agent/executor.py            |
                              |                               Priority-ordered handlers:
                         18 tool handlers                     1. ProductQuestionHandler (HIGHEST)
                         src/services/agent/handlers/         2. FailureAnalysisHandler (HIGH)
                              |                               3. RAGHandler (HIGH)
                              v                               4. TechnicalQuestionHandler (MEDIUM)
                         [Response assembly]                  5. FallbackHandler (LOWEST)
                              |                                    |
                              v                                    v
                    ┌─────────────────────────┐          ┌──────────────────┐
                    │  DB Persistence Layer    │          │  RAG Pipeline    │
                    │  conversation_messages   │          │  CleanRAGService │
                    │  chat_analytics_metrics  │          │  QueryAnalyzer   │
                    │  enhanced_rag_metrics    │          │  FolderRouter    │
                    └─────────────────────────┘          │  HybridSearch    │
                                                         └──────────────────┘
```

## Key Service Classes

| Service | File | Purpose |
|---------|------|---------|
| `ConversationManager` | `src/services/conversation_manager.py` | Main chat orchestration, message persistence |
| `AskGeorgeAgent` | `src/services/agent/agent.py` | Agentic mode LLM orchestrator with tool calling |
| `ToolExecutor` | `src/services/agent/executor.py` | Dispatches tool calls to handler registry |
| `UnifiedQueryClassifier` | `src/services/intelligence/unified_classifier.py` | LLM-based query intent classification (16 intents) |
| `CleanRAGService` | `src/services/clean_rag/clean_rag_service.py` | RAG: query analysis, folder routing, hybrid search |
| `RAGRetrievalService` | `src/services/intelligence/rag_retrieval_service.py` | Document retrieval with vector similarity |
| `TieredChatOrchestrator` | `src/services/handlers/orchestrator.py` | Legacy handler dispatch (priority-ordered) |
| `ComprehensiveRCFAAnalyzer` | `src/services/analysis/comprehensive_rcfa_analyzer.py` | RCFA failure analysis pipeline |
| `ProductLookupService` | `src/services/product_lookup_service.py` | Product catalog lookup (JSON-backed, singleton) |
| `TieredLLMClient` | `src/core/llm/tiered_client.py` | LLM routing with fallback tiers |
| `LLMRouter` | `src/core/llm/router.py` | Routes LLM calls to Azure OpenAI or Anthropic |
| `AzureConfig` | `src/core/azure_config.py` | Key Vault, Blob Storage, managed identity config |
| `WellContextFormatter` | `src/services/well_context_formatter.py` | Formats well/site data for RCFA context |
| `SynapseQueryValidator` | `src/services/synapse_query_validator.py` | SQL injection prevention for DAX/Synapse queries |

## RCFA Pipeline (Failure Analysis)

```
Image Upload (POST /api/v1/analysis/upload-image)
    |
    v
AnalysisSession created (status: initiated)
    |
    v
PyTorch model prediction (corrosion classifier)
    |
    v
GradCAM visualization generation
    |
    v
User provides survey context
    |
    v
ComprehensiveRCFAAnalyzer
    |── LLM analysis (60% context weight + 40% visual weight)
    |── Product recommendation generation
    |── Risk parameter calculation (CO2, H2S, bacteria, flow velocity, etc.)
    |── Report generation (Word/PPTX)
    |
    v
Results persisted to:
    rcfa_analytics (analysis + all extracted fields)
    product_recommendations (normalized per-product records)
    failure_analyses (formatted report)
```

## Error Points (Where Things Break)

| Step | Error Type | Impact | Signal Table |
|------|-----------|--------|-------------|
| LLM call | Timeout (>30s) | Fallback to lower tier or GPT5 fallback | `conversation_messages.latency_ms`, `timeout_analytics` |
| LLM call | API error | Fallback chain or error response | `chat_analytics_metrics`, `enhanced_rag_metrics` |
| RAG retrieval | No relevant docs | Low-quality response | `enhanced_rag_metrics.final_result_count` |
| RAG retrieval | Timeout | Degraded response | `timeout_analytics.timeout_type = 'rag_search_*'` |
| Classification | Low confidence | Wrong handler dispatched | `enhanced_rag_metrics.classification_confidence` |
| Product lookup | Code not found | Empty/wrong product info | `product_recommendation_analytics.success` |
| RCFA analysis | PyTorch timeout | Analysis proceeds without visual | `analysis_sessions.status = 'failed'` |
| RCFA analysis | Survey incomplete | Partial analysis, lower confidence | `rcfa_analytics.data_completeness_score` |
| DB persistence | Write failure | Lost analytics data | Application logs |
| Power BI DAX | Token refresh failure | No analytics data returned | `timeout_analytics.service_name = 'powerbi_mcp'` |

## Directory Map

```
src/api/routers/           14 HTTP routers (analysis.py = 8500 lines)
src/services/              48 service files + 18 subdirs
src/services/handlers/     9 query handlers (legacy dispatch)
src/services/analysis/     26 files (RCFA pipeline)
src/services/agent/        Agentic mode + 18 LLM tools
src/services/intelligence/ Classifier, RAG retrieval, progressive retrieval
src/services/clean_rag/    Query analysis, folder routing, hybrid search
src/core/llm/              LLM clients, tiered routing, factory, tool schemas
src/models/                29 SQLAlchemy model files
src/core/                  Config, DI container, database, auth, Azure config
frontend/                  React 18 + TypeScript SPA
tests/                     pytest suite
```

## Cross-References

- DB table details: [db-schema-map.md](db-schema-map.md)
- Error signal catalog: [error-signals.md](error-signals.md)
- Product data model: [product-catalog-reference.md](product-catalog-reference.md)
- Known failure patterns: [known-patterns.md](known-patterns.md)
