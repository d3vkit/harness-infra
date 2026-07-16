--
-- agent_harness — CANONICAL schema for the shared harness Postgres.
--
-- This repo owns the shared harness DB (compose.yaml here defines it;
-- script/build_global_rules.rb is the sole writer of the global* rule tiers), so this
-- file is the canonical schema.
--
-- Apps still keep their own db/harness_schema.sql forks (pamm, kyra_api, postcard) and their
-- ensure_schema still reads the local fork. Pointing them here is intended but NOT yet done —
-- nothing reads HARNESS_INFRA_ROOT today. Do not describe that mechanism as if it exists.
--
-- Rebuild the SQL body below from the live DB with:
--   docker exec -e PGPASSWORD=postgres agent-harness-infra-harness-db-1 \
--     pg_dump -U postgres -d postgres --schema-only --schema=agent_harness \
--     --no-owner --no-privileges | ruby script/clean_schema_dump.rb
-- That reproduces everything after this header, byte for byte. It does NOT reproduce the
-- header, so do not redirect it straight over this file — splice the body in beneath.
--
-- Two traps the cleaner exists to handle — do NOT reintroduce them by hand-dumping:
--
--   1. `\restrict` / `\unrestrict`. Recent pg_dump wraps its output in these (observed with
--      the 16.14 client in the harness container; the exact version that introduced them has
--      not been established here, so do not cite a threshold). They are *psql meta-commands*,
--      not SQL, so ensure_schema's `conn.exec(file.read)` (pg gem) dies on them. The app forks
--      lack them because each fork's header documents removing them BY HAND after dumping —
--      an easy step to forget, which is why this is automated here.
--
--   2. `SET transaction_timeout`. A PostgreSQL 17+ GUC. The harness DB is postgres:16
--      (see compose.yaml), which errors with "unrecognized configuration parameter".
--      A dump taken from a PG17 client reintroduces it.
--
--
-- PostgreSQL database dump
--


-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: agent_harness; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA agent_harness;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agent_sessions; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.agent_sessions (
    session_id text NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    started_at timestamp with time zone,
    ended_at timestamp with time zone,
    title text,
    branch text,
    prompt text,
    model text,
    summary text,
    tool_count integer DEFAULT 0,
    files_changed text[],
    outcome text,
    is_last boolean DEFAULT false,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((((COALESCE(title, ''::text) || ' '::text) || COALESCE(prompt, ''::text)) || ' '::text) || COALESCE(summary, ''::text)))) STORED
);


--
-- Name: decisions; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.decisions (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    title text NOT NULL,
    context text NOT NULL,
    decision text NOT NULL,
    rationale text NOT NULL,
    source_file text,
    decided_at timestamp with time zone DEFAULT now(),
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((((((title || ' '::text) || context) || ' '::text) || decision) || ' '::text) || rationale))) STORED
);


--
-- Name: decisions_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.decisions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: decisions_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.decisions_id_seq OWNED BY agent_harness.decisions.id;


--
-- Name: docs; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.docs (
    slug text NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    topic text NOT NULL,
    summary text NOT NULL,
    source_file text NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((topic || ' '::text) || summary))) STORED
);


--
-- Name: endpoints; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.endpoints (
    id integer NOT NULL,
    method text NOT NULL,
    path text NOT NULL,
    domain text NOT NULL,
    auth_mode text NOT NULL,
    csrf text NOT NULL,
    contract_md text NOT NULL,
    source_file text NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, contract_md)) STORED
);


--
-- Name: endpoints_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.endpoints_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: endpoints_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.endpoints_id_seq OWNED BY agent_harness.endpoints.id;


--
-- Name: enumerations; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.enumerations (
    id integer NOT NULL,
    model text NOT NULL,
    column_name text NOT NULL,
    values_json jsonb NOT NULL
);


--
-- Name: enumerations_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.enumerations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enumerations_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.enumerations_id_seq OWNED BY agent_harness.enumerations.id;


--
-- Name: feature_docs; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.feature_docs (
    slug text NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    title text NOT NULL,
    feature_area text[] DEFAULT '{}'::text[] NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    summary text NOT NULL,
    full_text text NOT NULL,
    source_file text NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || full_text))) STORED
);


--
-- Name: feature_plans; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.feature_plans (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    title text NOT NULL,
    feature_slugs text[] DEFAULT '{}'::text[] NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    summary text NOT NULL,
    full_text text NOT NULL,
    decided_at timestamp with time zone,
    source_file text NOT NULL,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || full_text))) STORED
);


--
-- Name: feature_plans_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.feature_plans_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: feature_plans_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.feature_plans_id_seq OWNED BY agent_harness.feature_plans.id;


--
-- Name: fix_plans; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.fix_plans (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    rule_id integer,
    title text NOT NULL,
    target_files text[] NOT NULL,
    instructions text NOT NULL,
    verification text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    source_file text,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || instructions))) STORED
);


--
-- Name: fix_plans_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.fix_plans_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fix_plans_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.fix_plans_id_seq OWNED BY agent_harness.fix_plans.id;


--
-- Name: invariants; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.invariants (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    description text NOT NULL,
    enforcement text NOT NULL,
    consequence text NOT NULL,
    source_file text,
    tags text[],
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((((description || ' '::text) || enforcement) || ' '::text) || consequence))) STORED
);


--
-- Name: invariants_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.invariants_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invariants_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.invariants_id_seq OWNED BY agent_harness.invariants.id;


--
-- Name: patterns; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.patterns (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    when_to_use text NOT NULL,
    steps text[] NOT NULL,
    example_files text[],
    tags text[],
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || when_to_use))) STORED
);


--
-- Name: patterns_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.patterns_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: patterns_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.patterns_id_seq OWNED BY agent_harness.patterns.id;


--
-- Name: roles; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.roles (
    slug text NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    display_name text NOT NULL,
    trigger_when text NOT NULL,
    source_file text NOT NULL
);


--
-- Name: rules; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.rules (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    role text NOT NULL,
    category text NOT NULL,
    severity text NOT NULL,
    rule_text text NOT NULL,
    source_file text NOT NULL,
    source_heading text,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, rule_text)) STORED
);


--
-- Name: rules_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.rules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rules_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.rules_id_seq OWNED BY agent_harness.rules.id;


--
-- Name: sharp_edges; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.sharp_edges (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    mitigation text NOT NULL,
    source_file text,
    tags text[],
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((((title || ' '::text) || description) || ' '::text) || mitigation))) STORED
);


--
-- Name: sharp_edges_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.sharp_edges_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sharp_edges_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.sharp_edges_id_seq OWNED BY agent_harness.sharp_edges.id;


--
-- Name: specialist_findings; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.specialist_findings (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    specialty text NOT NULL,
    session_id text,
    ticket_id text,
    finding_type text NOT NULL,
    title text NOT NULL,
    details text NOT NULL,
    affected_files text[],
    severity text DEFAULT 'standard'::text NOT NULL,
    superseded_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((title || ' '::text) || details))) STORED,
    CONSTRAINT specialist_findings_severity_chk CHECK ((severity = ANY (ARRAY['critical'::text, 'standard'::text, 'advisory'::text]))),
    CONSTRAINT specialist_findings_type_chk CHECK ((finding_type = ANY (ARRAY['insight'::text, 'pitfall'::text, 'pattern'::text, 'risk'::text, 'open_question'::text])))
);


--
-- Name: specialist_findings_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.specialist_findings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: specialist_findings_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.specialist_findings_id_seq OWNED BY agent_harness.specialist_findings.id;


--
-- Name: work_log; Type: TABLE; Schema: agent_harness; Owner: -
--

CREATE TABLE agent_harness.work_log (
    id integer NOT NULL,
    app text DEFAULT 'pamm'::text NOT NULL,
    entry_type text NOT NULL,
    title text NOT NULL,
    body text,
    status text DEFAULT 'open'::text NOT NULL,
    ticket_id text,
    priority smallint DEFAULT 3,
    branch text,
    session_id text,
    related_files text[],
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    superseded_by integer,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, ((COALESCE(title, ''::text) || ' '::text) || COALESCE(body, ''::text)))) STORED,
    CONSTRAINT work_log_entry_type_chk CHECK ((entry_type = ANY (ARRAY['todo'::text, 'done'::text, 'resume'::text]))),
    CONSTRAINT work_log_status_chk CHECK ((status = ANY (ARRAY['open'::text, 'in_progress'::text, 'blocked'::text, 'done'::text, 'archived'::text])))
);


--
-- Name: work_log_id_seq; Type: SEQUENCE; Schema: agent_harness; Owner: -
--

CREATE SEQUENCE agent_harness.work_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_log_id_seq; Type: SEQUENCE OWNED BY; Schema: agent_harness; Owner: -
--

ALTER SEQUENCE agent_harness.work_log_id_seq OWNED BY agent_harness.work_log.id;


--
-- Name: decisions id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.decisions ALTER COLUMN id SET DEFAULT nextval('agent_harness.decisions_id_seq'::regclass);


--
-- Name: endpoints id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.endpoints ALTER COLUMN id SET DEFAULT nextval('agent_harness.endpoints_id_seq'::regclass);


--
-- Name: enumerations id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.enumerations ALTER COLUMN id SET DEFAULT nextval('agent_harness.enumerations_id_seq'::regclass);


--
-- Name: feature_plans id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.feature_plans ALTER COLUMN id SET DEFAULT nextval('agent_harness.feature_plans_id_seq'::regclass);


--
-- Name: fix_plans id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.fix_plans ALTER COLUMN id SET DEFAULT nextval('agent_harness.fix_plans_id_seq'::regclass);


--
-- Name: invariants id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.invariants ALTER COLUMN id SET DEFAULT nextval('agent_harness.invariants_id_seq'::regclass);


--
-- Name: patterns id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.patterns ALTER COLUMN id SET DEFAULT nextval('agent_harness.patterns_id_seq'::regclass);


--
-- Name: rules id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.rules ALTER COLUMN id SET DEFAULT nextval('agent_harness.rules_id_seq'::regclass);


--
-- Name: sharp_edges id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.sharp_edges ALTER COLUMN id SET DEFAULT nextval('agent_harness.sharp_edges_id_seq'::regclass);


--
-- Name: specialist_findings id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.specialist_findings ALTER COLUMN id SET DEFAULT nextval('agent_harness.specialist_findings_id_seq'::regclass);


--
-- Name: work_log id; Type: DEFAULT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.work_log ALTER COLUMN id SET DEFAULT nextval('agent_harness.work_log_id_seq'::regclass);


--
-- Name: agent_sessions agent_sessions_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.agent_sessions
    ADD CONSTRAINT agent_sessions_pkey PRIMARY KEY (session_id);


--
-- Name: decisions decisions_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.decisions
    ADD CONSTRAINT decisions_pkey PRIMARY KEY (id);


--
-- Name: docs docs_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.docs
    ADD CONSTRAINT docs_pkey PRIMARY KEY (app, slug);


--
-- Name: endpoints endpoints_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.endpoints
    ADD CONSTRAINT endpoints_pkey PRIMARY KEY (id);


--
-- Name: enumerations enumerations_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.enumerations
    ADD CONSTRAINT enumerations_pkey PRIMARY KEY (id);


--
-- Name: feature_docs feature_docs_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.feature_docs
    ADD CONSTRAINT feature_docs_pkey PRIMARY KEY (app, slug);


--
-- Name: feature_plans feature_plans_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.feature_plans
    ADD CONSTRAINT feature_plans_pkey PRIMARY KEY (id);


--
-- Name: fix_plans fix_plans_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.fix_plans
    ADD CONSTRAINT fix_plans_pkey PRIMARY KEY (id);


--
-- Name: invariants invariants_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.invariants
    ADD CONSTRAINT invariants_pkey PRIMARY KEY (id);


--
-- Name: patterns patterns_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.patterns
    ADD CONSTRAINT patterns_pkey PRIMARY KEY (id);


--
-- Name: patterns patterns_slug_key; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.patterns
    ADD CONSTRAINT patterns_slug_key UNIQUE (app, slug);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (app, slug);


--
-- Name: rules rules_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.rules
    ADD CONSTRAINT rules_pkey PRIMARY KEY (id);


--
-- Name: sharp_edges sharp_edges_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.sharp_edges
    ADD CONSTRAINT sharp_edges_pkey PRIMARY KEY (id);


--
-- Name: specialist_findings specialist_findings_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.specialist_findings
    ADD CONSTRAINT specialist_findings_pkey PRIMARY KEY (id);


--
-- Name: work_log work_log_pkey; Type: CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.work_log
    ADD CONSTRAINT work_log_pkey PRIMARY KEY (id);


--
-- Name: agent_sessions_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX agent_sessions_app ON agent_harness.agent_sessions USING btree (app);


--
-- Name: agent_sessions_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX agent_sessions_fts ON agent_harness.agent_sessions USING gin (search_vector);


--
-- Name: decisions_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX decisions_app ON agent_harness.decisions USING btree (app);


--
-- Name: decisions_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX decisions_fts ON agent_harness.decisions USING gin (search_vector);


--
-- Name: docs_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX docs_app ON agent_harness.docs USING btree (app);


--
-- Name: docs_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX docs_fts ON agent_harness.docs USING gin (search_vector);


--
-- Name: endpoints_domain; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX endpoints_domain ON agent_harness.endpoints USING btree (domain);


--
-- Name: endpoints_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX endpoints_fts ON agent_harness.endpoints USING gin (search_vector);


--
-- Name: endpoints_method_path; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX endpoints_method_path ON agent_harness.endpoints USING btree (method, path);


--
-- Name: feature_docs_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_docs_app ON agent_harness.feature_docs USING btree (app);


--
-- Name: feature_docs_area; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_docs_area ON agent_harness.feature_docs USING gin (feature_area);


--
-- Name: feature_docs_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_docs_fts ON agent_harness.feature_docs USING gin (search_vector);


--
-- Name: feature_docs_status; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_docs_status ON agent_harness.feature_docs USING btree (status);


--
-- Name: feature_plans_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_plans_app ON agent_harness.feature_plans USING btree (app);


--
-- Name: feature_plans_decided_at; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_plans_decided_at ON agent_harness.feature_plans USING btree (decided_at DESC NULLS LAST);


--
-- Name: feature_plans_feature_slugs; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_plans_feature_slugs ON agent_harness.feature_plans USING gin (feature_slugs);


--
-- Name: feature_plans_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_plans_fts ON agent_harness.feature_plans USING gin (search_vector);


--
-- Name: feature_plans_status; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX feature_plans_status ON agent_harness.feature_plans USING btree (status);


--
-- Name: fix_plans_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX fix_plans_app ON agent_harness.fix_plans USING btree (app);


--
-- Name: fix_plans_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX fix_plans_fts ON agent_harness.fix_plans USING gin (search_vector);


--
-- Name: fix_plans_rule; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX fix_plans_rule ON agent_harness.fix_plans USING btree (rule_id);


--
-- Name: fix_plans_status; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX fix_plans_status ON agent_harness.fix_plans USING btree (status);


--
-- Name: invariants_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX invariants_app ON agent_harness.invariants USING btree (app);


--
-- Name: invariants_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX invariants_fts ON agent_harness.invariants USING gin (search_vector);


--
-- Name: invariants_tags; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX invariants_tags ON agent_harness.invariants USING gin (tags);


--
-- Name: patterns_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX patterns_app ON agent_harness.patterns USING btree (app);


--
-- Name: patterns_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX patterns_fts ON agent_harness.patterns USING gin (search_vector);


--
-- Name: patterns_tags; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX patterns_tags ON agent_harness.patterns USING gin (tags);


--
-- Name: roles_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX roles_app ON agent_harness.roles USING btree (app);


--
-- Name: rules_app_role_category; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX rules_app_role_category ON agent_harness.rules USING btree (app, role, category);


--
-- Name: rules_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX rules_fts ON agent_harness.rules USING gin (search_vector);


--
-- Name: rules_role_category; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX rules_role_category ON agent_harness.rules USING btree (role, category);


--
-- Name: rules_severity; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX rules_severity ON agent_harness.rules USING btree (severity);


--
-- Name: sharp_edges_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX sharp_edges_app ON agent_harness.sharp_edges USING btree (app);


--
-- Name: sharp_edges_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX sharp_edges_fts ON agent_harness.sharp_edges USING gin (search_vector);


--
-- Name: sharp_edges_tags; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX sharp_edges_tags ON agent_harness.sharp_edges USING gin (tags);


--
-- Name: specialist_findings_app; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX specialist_findings_app ON agent_harness.specialist_findings USING btree (app);


--
-- Name: specialist_findings_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX specialist_findings_fts ON agent_harness.specialist_findings USING gin (search_vector);


--
-- Name: specialist_findings_open; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX specialist_findings_open ON agent_harness.specialist_findings USING btree (specialty, resolved_at) WHERE (resolved_at IS NULL);


--
-- Name: specialist_findings_session; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX specialist_findings_session ON agent_harness.specialist_findings USING btree (session_id);


--
-- Name: specialist_findings_specialty; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX specialist_findings_specialty ON agent_harness.specialist_findings USING btree (specialty);


--
-- Name: work_log_app_type_status; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX work_log_app_type_status ON agent_harness.work_log USING btree (app, entry_type, status);


--
-- Name: work_log_fts; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX work_log_fts ON agent_harness.work_log USING gin (search_vector);


--
-- Name: work_log_one_open_resume; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE UNIQUE INDEX work_log_one_open_resume ON agent_harness.work_log USING btree (app) WHERE ((entry_type = 'resume'::text) AND (status = 'open'::text));


--
-- Name: work_log_ticket_id; Type: INDEX; Schema: agent_harness; Owner: -
--

CREATE INDEX work_log_ticket_id ON agent_harness.work_log USING btree (ticket_id);


--
-- Name: fix_plans fix_plans_rule_id_fkey; Type: FK CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.fix_plans
    ADD CONSTRAINT fix_plans_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES agent_harness.rules(id);


--
-- Name: specialist_findings specialist_findings_superseded_fkey; Type: FK CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.specialist_findings
    ADD CONSTRAINT specialist_findings_superseded_fkey FOREIGN KEY (superseded_by) REFERENCES agent_harness.specialist_findings(id);


--
-- Name: work_log work_log_superseded_fkey; Type: FK CONSTRAINT; Schema: agent_harness; Owner: -
--

ALTER TABLE ONLY agent_harness.work_log
    ADD CONSTRAINT work_log_superseded_fkey FOREIGN KEY (superseded_by) REFERENCES agent_harness.work_log(id);


--
-- PostgreSQL database dump complete
--


