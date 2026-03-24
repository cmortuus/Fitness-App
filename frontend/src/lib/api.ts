import axios, { AxiosError } from 'axios';

const api = axios.create({
  baseURL: '/api',
  headers: {
    'Content-Type': 'application/json',
  },
  timeout: 10000,
});

// Attach auth token to every request
api.interceptors.request.use((config) => {
  if (typeof localStorage !== 'undefined') {
    const token = localStorage.getItem('hgt_access_token');
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
  }
  return config;
});

// Handle responses — redirect to login on 401
api.interceptors.response.use(
  (response) => response,
  async (error: AxiosError) => {
    if (error.response?.status === 401 && typeof window !== 'undefined') {
      // Try refresh token
      const refreshToken = localStorage.getItem('hgt_refresh_token');
      if (refreshToken && error.config && !error.config.url?.includes('/auth/')) {
        try {
          const r = await axios.post('/api/auth/refresh', { refresh_token: refreshToken });
          localStorage.setItem('hgt_access_token', r.data.access_token);
          localStorage.setItem('hgt_refresh_token', r.data.refresh_token);
          // Retry original request
          error.config.headers.Authorization = `Bearer ${r.data.access_token}`;
          return api.request(error.config);
        } catch {
          // Refresh failed — clear tokens and redirect
          localStorage.removeItem('hgt_access_token');
          localStorage.removeItem('hgt_refresh_token');
          localStorage.removeItem('hgt_user');
          window.location.href = '/login';
          return Promise.reject(error);
        }
      }
      // No refresh token — redirect to login
      if (!window.location.pathname.startsWith('/login') && !window.location.pathname.startsWith('/signup')) {
        localStorage.removeItem('hgt_access_token');
        localStorage.removeItem('hgt_refresh_token');
        localStorage.removeItem('hgt_user');
        window.location.href = '/login';
      }
    } else if (error.response) {
      console.error('API Error:', error.response.status, error.response.data);
    } else if (error.request) {
      console.error('Network Error: No response received');
    } else {
      console.error('Request Error:', error.message);
    }
    return Promise.reject(error);
  }
);

// ── Auth API ─────────────────────────────────────────────────────────────────

export interface AuthUser {
  id: number;
  username: string;
  email: string;
  created_at: string;
}

export interface AuthResponse {
  access_token: string;
  refresh_token: string;
  token_type: string;
  user: AuthUser;
}

export async function authRegister(data: { username: string; password: string; email?: string }): Promise<AuthResponse> {
  const response = await api.post('/auth/register', data);
  return response.data;
}

export async function authLogin(data: { username: string; password: string }): Promise<AuthResponse> {
  const response = await api.post('/auth/login', data);
  return response.data;
}

export async function authGetMe(): Promise<AuthUser> {
  const response = await api.get('/auth/me');
  return response.data;
}

export function saveAuthTokens(auth: AuthResponse): void {
  localStorage.setItem('hgt_access_token', auth.access_token);
  localStorage.setItem('hgt_refresh_token', auth.refresh_token);
  localStorage.setItem('hgt_user', JSON.stringify(auth.user));
}

export function clearAuthTokens(): void {
  localStorage.removeItem('hgt_access_token');
  localStorage.removeItem('hgt_refresh_token');
  localStorage.removeItem('hgt_user');
}

export function getStoredUser(): AuthUser | null {
  if (typeof localStorage === 'undefined') return null;
  const raw = localStorage.getItem('hgt_user');
  return raw ? JSON.parse(raw) : null;
}

export function isAuthenticated(): boolean {
  if (typeof localStorage === 'undefined') return false;
  return !!localStorage.getItem('hgt_access_token');
}

// Types
export interface Exercise {
  id: number;
  name: string;
  display_name: string;
  movement_type: 'compound' | 'isolation';
  body_region: 'upper' | 'lower' | 'full_body';
  is_unilateral: boolean;
  is_assisted: boolean;
  description: string | null;
  primary_muscles: string[];
  secondary_muscles: string[];
}

export interface RecentExercise extends Exercise {
  usage_count: number;
  last_used: string | null;
}

export interface Set {
  id: number;
  exercise_id: number;
  set_number: number;
  planned_reps: number | null;
  planned_reps_left: number | null;
  planned_reps_right: number | null;
  planned_weight_kg: number | null;
  actual_reps: number | null;
  actual_weight_kg: number | null;
  reps_left: number | null;
  reps_right: number | null;
  notes: string | null;
  started_at: string | null;
  completed_at: string | null;
}

export interface WorkoutSession {
  id: number;
  name: string | null;
  date: string;
  status: 'planned' | 'in_progress' | 'completed' | 'skipped';
  workout_plan_id: number | null;
  total_volume_kg: number;
  total_sets: number;
  total_reps: number;
  started_at: string | null;
  completed_at: string | null;
  sets: Set[];
}

export interface PlannedExercise {
  exercise_id: number;
  sets: number;
  reps: number;
  starting_weight_kg: number;
  progression_type: string;
  rest_seconds?: number;
  notes?: string | null;
}

export interface PlannedDay {
  day_number: number;
  day_name: string;
  exercises: PlannedExercise[];
}

export interface WorkoutPlan {
  id: number;
  name: string;
  description: string | null;
  block_type: string;
  duration_weeks: number;
  current_week: number;
  number_of_days: number;
  days: PlannedDay[];
  auto_progression: boolean;
  min_technique_score: number;
  is_draft: boolean;
  is_archived: boolean;
}

export interface ProgressMetric {
  exercise_id: number;
  exercise_name: string;
  date: string;
  estimated_1rm: number | null;
  volume_load: number;
  recommended_weight: number | null;
}

export interface ProgressionRecommendation {
  exercise_id: number;
  exercise_name: string;
  current_weight: number;
  recommended_weight: number;
  reason: string;
  confidence: number;
}

// API Functions

// Sessions
export async function getSessions(params?: { limit?: number; offset?: number }): Promise<WorkoutSession[]> {
  const response = await api.get('/sessions/', { params });
  return response.data;
}

export async function createSession(data: {
  name?: string;
  date: string;
  workout_plan_id?: number;
}): Promise<WorkoutSession> {
  const response = await api.post('/sessions/', data);
  return response.data;
}

export async function createSessionFromPlan(
  planId: number,
  dayNumber: number = 1,
  overloadStyle: 'rep' | 'weight' = 'rep',
  bodyWeightKg: number = 0
): Promise<WorkoutSession> {
  const response = await api.post(
    `/sessions/from-plan/${planId}?day_number=${dayNumber}&overload_style=${overloadStyle}&body_weight_kg=${bodyWeightKg}`
  );
  return response.data;
}

export async function getSession(sessionId: number): Promise<WorkoutSession> {
  const response = await api.get(`/sessions/${sessionId}`);
  return response.data;
}

export async function startSession(sessionId: number): Promise<WorkoutSession> {
  const response = await api.post(`/sessions/${sessionId}/start`);
  return response.data;
}

export async function completeSession(sessionId: number): Promise<WorkoutSession> {
  const response = await api.post(`/sessions/${sessionId}/complete`);
  return response.data;
}

export async function addSet(
  sessionId: number,
  data: {
    exercise_id: number;
    set_number: number;
    planned_reps?: number;
    planned_weight_kg?: number;
  }
): Promise<Set> {
  const response = await api.post(`/sessions/${sessionId}/sets`, data);
  return response.data;
}

export async function updateSet(
  sessionId: number,
  setId: number,
  data: Partial<Set>
): Promise<Set> {
  const response = await api.patch(`/sessions/${sessionId}/sets/${setId}`, data);
  return response.data;
}

export async function deleteSet(sessionId: number, setId: number): Promise<void> {
  await api.delete(`/sessions/${sessionId}/sets/${setId}`);
}

export async function deleteSession(sessionId: number): Promise<void> {
  await api.delete(`/sessions/${sessionId}`);
}

// Exercises
export async function getExercises(): Promise<Exercise[]> {
  const response = await api.get('/exercises/');
  return response.data;
}

export async function getExercise(exerciseId: number): Promise<Exercise> {
  const response = await api.get(`/exercises/${exerciseId}`);
  return response.data;
}

export async function createExercise(data: {
  name: string;
  display_name: string;
  movement_type?: 'compound' | 'isolation';
  body_region?: 'upper' | 'lower' | 'full_body';
  description?: string;
  primary_muscles?: string[];
  secondary_muscles?: string[];
}): Promise<Exercise> {
  const response = await api.post('/exercises/', data);
  return response.data;
}

export async function deleteExercise(exerciseId: number): Promise<void> {
  await api.delete(`/exercises/${exerciseId}`);
}

export interface ExerciseHistorySession {
  session_id: number;
  session_name: string | null;
  workout_plan_id: number | null;
  plan_name?: string;
  date: string;
  week_number: number | null;
  sets: {
    set_number: number;
    actual_reps: number | null;
    reps_left: number | null;
    reps_right: number | null;
    actual_weight_kg: number | null;
    notes: string | null;
  }[];
}

export async function getExerciseHistory(exerciseId: number, limit: number = 8): Promise<ExerciseHistorySession[]> {
  const response = await api.get(`/exercises/${exerciseId}/history`, { params: { limit } });
  return response.data;
}

// Get recently used exercises
export async function getRecentExercises(limit: number = 10): Promise<RecentExercise[]> {
  const response = await api.get('/plans/exercises/recent', { params: { limit } });
  return response.data;
}

// Get exercises grouped by muscle group
export async function getExercisesGrouped(): Promise<Record<string, Exercise[]>> {
  const response = await api.get('/plans/exercises/grouped');
  return response.data;
}

// Progress
export async function getProgress(params?: {
  exercise_id?: number;
  start_date?: string;
  end_date?: string;
}): Promise<ProgressMetric[]> {
  const response = await api.get('/progress/', { params });
  return response.data;
}

export async function getRecommendations(daysBack: number = 30): Promise<ProgressionRecommendation[]> {
  const response = await api.get('/progress/recommendations', { params: { days_back: daysBack } });
  return response.data;
}

// Plans
export async function getPlans(): Promise<WorkoutPlan[]> {
  const response = await api.get('/plans/');
  return response.data;
}

export async function getPlan(planId: number): Promise<WorkoutPlan> {
  const response = await api.get(`/plans/${planId}`);
  return response.data;
}

export async function createPlan(data: {
  name: string;
  description?: string;
  block_type?: string;
  duration_weeks?: number;
  number_of_days: number;
  days: PlannedDay[];
  auto_progression?: boolean;
  min_technique_score?: number;
  is_draft?: boolean;
}): Promise<WorkoutPlan> {
  const response = await api.post('/plans/', data);
  return response.data;
}

export async function getPlansWithDrafts(): Promise<WorkoutPlan[]> {
  const response = await api.get('/plans/?drafts=true');
  return response.data;
}

export async function deletePlan(planId: number): Promise<void> {
  await api.delete(`/plans/${planId}`);
}

export async function archivePlan(planId: number): Promise<WorkoutPlan> {
  const response = await api.post(`/plans/${planId}/archive`);
  return response.data;
}

export async function publishPlan(planId: number): Promise<WorkoutPlan> {
  const response = await api.post(`/plans/${planId}/publish`);
  return response.data;
}

export async function reusePlan(planId: number): Promise<WorkoutPlan> {
  const response = await api.post(`/plans/${planId}/reuse`);
  return response.data;
}

export async function updatePlan(planId: number, data: {
  name?: string;
  description?: string;
  block_type?: string;
  duration_weeks?: number;
  number_of_days?: number;
  days?: PlannedDay[];
  auto_progression?: boolean;
}): Promise<WorkoutPlan> {
  const response = await api.put(`/plans/${planId}`, data);
  return response.data;
}

// Body weight
export interface BodyWeightEntry {
  id: number;
  weight_kg: number;
  body_fat_pct: number | null;
  fat_mass_kg?: number;
  lean_mass_kg?: number;
  recorded_at: string;
  notes: string | null;
}

export async function getBodyWeights(limit: number = 50): Promise<BodyWeightEntry[]> {
  const response = await api.get('/body-weight/', { params: { limit } });
  return response.data;
}

export async function getLatestBodyWeight(): Promise<BodyWeightEntry | null> {
  const response = await api.get('/body-weight/latest');
  return response.data;
}

export async function addBodyWeight(data: {
  weight_kg: number;
  body_fat_pct?: number | null;
  recorded_at?: string;
  notes?: string;
}): Promise<BodyWeightEntry> {
  const response = await api.post('/body-weight/', data);
  return response.data;
}

export async function deleteBodyWeight(entryId: number): Promise<void> {
  await api.delete(`/body-weight/${entryId}`);
}

// ── Nutrition ────────────────────────────────────────────────────────────────

export type Micronutrients = Record<string, number>;

export const MICRO_META: Record<string, { label: string; unit: string; rda: number | null }> = {
  fiber_g: { label: 'Fiber', unit: 'g', rda: 28 },
  sugar_g: { label: 'Sugar', unit: 'g', rda: null },
  sodium_mg: { label: 'Sodium', unit: 'mg', rda: 2300 },
  calcium_mg: { label: 'Calcium', unit: 'mg', rda: 1000 },
  iron_mg: { label: 'Iron', unit: 'mg', rda: 18 },
  magnesium_mg: { label: 'Magnesium', unit: 'mg', rda: 400 },
  potassium_mg: { label: 'Potassium', unit: 'mg', rda: 2600 },
  zinc_mg: { label: 'Zinc', unit: 'mg', rda: 11 },
  phosphorus_mg: { label: 'Phosphorus', unit: 'mg', rda: 700 },
  vitamin_a_mcg: { label: 'Vitamin A', unit: 'mcg', rda: 900 },
  vitamin_c_mg: { label: 'Vitamin C', unit: 'mg', rda: 90 },
  vitamin_d_mcg: { label: 'Vitamin D', unit: 'mcg', rda: 20 },
  vitamin_e_mg: { label: 'Vitamin E', unit: 'mg', rda: 15 },
  vitamin_b12_mcg: { label: 'Vitamin B12', unit: 'mcg', rda: 2.4 },
  cholesterol_mg: { label: 'Cholesterol', unit: 'mg', rda: null },
  omega3_g: { label: 'Omega-3', unit: 'g', rda: 1.6 },
};

export interface FoodSearchResult {
  name: string;
  brand: string | null;
  source: 'openfoodfacts' | 'usda' | 'custom';
  source_id: string | null;
  barcode: string | null;
  calories_per_100g: number | null;
  protein_per_100g: number | null;
  carbs_per_100g: number | null;
  fat_per_100g: number | null;
  serving_size_g: number;
  serving_label: string | null;
  micronutrients?: Micronutrients | null;
}

export interface FoodItem extends FoodSearchResult {
  id: number;
  is_custom: boolean;
}

export interface NutritionEntry {
  id: number;
  food_item_id: number | null;
  name: string;
  date: string;
  meal: 'breakfast' | 'lunch' | 'dinner' | 'snack';
  quantity_g: number;
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
  micronutrients?: Micronutrients | null;
  logged_at: string;
}

export interface MacroGoals {
  id: number;
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
  effective_from: string;
}

export interface DailySummary {
  date: string;
  totals: { calories: number; protein: number; carbs: number; fat: number };
  goals: MacroGoals | null;
  remaining: { calories: number; protein: number; carbs: number; fat: number } | null;
}

export interface DailyEntries {
  date: string;
  meals: Record<string, NutritionEntry[]>;
  totals: { calories: number; protein: number; carbs: number; fat: number };
}

// Food search
export async function searchFoods(q: string, page: number = 1): Promise<FoodSearchResult[]> {
  const response = await api.get('/nutrition/search', { params: { q, page } });
  return response.data;
}

export async function lookupBarcode(code: string): Promise<FoodSearchResult> {
  const response = await api.get(`/nutrition/barcode/${code}`);
  return response.data;
}

// Custom foods
export async function getCustomFoods(q: string = ''): Promise<FoodItem[]> {
  const response = await api.get('/nutrition/foods', { params: { q } });
  return response.data;
}

export async function createCustomFood(data: {
  name: string;
  brand?: string;
  barcode?: string;
  calories_per_100g: number;
  protein_per_100g: number;
  carbs_per_100g: number;
  fat_per_100g: number;
  serving_size_g?: number;
  serving_label?: string;
}): Promise<FoodItem> {
  const response = await api.post('/nutrition/foods', data);
  return response.data;
}

export async function deleteCustomFood(id: number): Promise<void> {
  await api.delete(`/nutrition/foods/${id}`);
}

// Nutrition entries
export async function getNutritionEntries(date: string): Promise<DailyEntries> {
  const response = await api.get('/nutrition/entries', { params: { date } });
  return response.data;
}

export async function addNutritionEntry(data: {
  food_item_id?: number;
  name: string;
  date: string;
  meal?: string;
  quantity_g: number;
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
}): Promise<NutritionEntry> {
  const response = await api.post('/nutrition/entries', data);
  return response.data;
}

export async function deleteNutritionEntry(id: number): Promise<void> {
  await api.delete(`/nutrition/entries/${id}`);
}

// Summary & goals
export async function getDailySummary(date: string): Promise<DailySummary> {
  const response = await api.get('/nutrition/summary', { params: { date } });
  return response.data;
}

export async function getMacroGoals(): Promise<MacroGoals | null> {
  const response = await api.get('/nutrition/goals');
  return response.data;
}

export async function setMacroGoals(data: {
  calories: number;
  protein: number;
  carbs: number;
  fat: number;
  effective_from?: string;
}): Promise<MacroGoals> {
  const response = await api.put('/nutrition/goals', data);
  return response.data;
}

// Insights
export interface Insight {
  type: 'success' | 'warning' | 'info';
  icon: string;
  text: string;
}

export async function getInsights(): Promise<Insight[]> {
  const response = await api.get('/progress/insights');
  return response.data;
}

// Weekly report
export interface WeeklyReport {
  period: { start: string; end: string };
  days: { date: string; calories: number; protein: number; carbs: number; fat: number }[];
  averages: { calories: number; protein: number; carbs: number; fat: number };
  days_logged: number;
  goals: { calories: number; protein: number; carbs: number; fat: number } | null;
  weight_data: { date: string; weight_kg: number; body_fat_pct: number | null; lean_mass_kg: number | null }[];
  weight_change_kg: number | null;
  workout_count: number;
}

export async function getWeeklyReport(): Promise<WeeklyReport> {
  const response = await api.get('/nutrition/weekly-report');
  return response.data;
}

// ── Diet Phases ──────────────────────────────────────────────────────────────

export interface DietPhase {
  id: number;
  phase_type: 'cut' | 'bulk' | 'maintenance';
  started_on: string;
  duration_weeks: number;
  current_week: number;
  weeks_remaining: number;
  starting_weight_kg: number;
  current_weight_kg: number | null;
  target_weight_kg: number;
  weight_change_kg: number;
  target_rate_pct: number;
  actual_rate_pct: number | null;
  status: 'on_track' | 'behind' | 'ahead' | 'no_data';
  suggestion: string | null;
  current_goals: { calories: number; protein: number; carbs: number; fat: number };
  carb_preset: 'high' | 'moderate' | 'low';
  tdee_estimate: number;
  is_active: boolean;
}

export async function getActivePhase(): Promise<DietPhase | null> {
  const response = await api.get('/nutrition/phases/active');
  return response.data;
}

export async function createPhase(data: {
  phase_type: 'cut' | 'bulk' | 'maintenance';
  duration_weeks?: number;
  target_rate_pct?: number;
  activity_multiplier?: number;
  tdee_override?: number | null;
  carb_preset?: 'high' | 'moderate' | 'low';
  body_fat_pct?: number | null;
  protein_per_lb?: number | null;
}): Promise<DietPhase> {
  const response = await api.post('/nutrition/phases/', data);
  return response.data;
}

export async function recalculatePhase(apply: boolean = false): Promise<DietPhase> {
  const response = await api.post('/nutrition/phases/active/recalculate', null, { params: { apply } });
  return response.data;
}

export async function endPhase(): Promise<void> {
  await api.delete('/nutrition/phases/active');
}

// ── Workout Templates ────────────────────────────────────────────────────────

export interface WorkoutTemplateDay {
  day_number: number;
  day_name: string;
  exercises: { exercise_id: number; sets: number; reps: number; starting_weight_kg: number; progression_type: string }[];
}

export interface WorkoutTemplate {
  id: number;
  name: string;
  split_type: string;
  days_per_week: number;
  equipment_tier: string;
  description: string;
  block_type: string;
  exercise_count: number;
  days: WorkoutTemplateDay[];
}

export async function getTemplates(params?: {
  split_type?: string;
  equipment_tier?: string;
  days_per_week?: number;
}): Promise<WorkoutTemplate[]> {
  const response = await api.get('/templates/', { params });
  return response.data;
}

export async function getTemplate(id: number): Promise<WorkoutTemplate> {
  const response = await api.get(`/templates/${id}`);
  return response.data;
}

export async function cloneTemplate(id: number): Promise<{ id: number; name: string; message: string }> {
  const response = await api.post(`/templates/${id}/clone`);
  return response.data;
}

export default api;
