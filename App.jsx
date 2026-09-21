import { useEffect, useState } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { hasSupabase, supabase } from "./lib/supabase";
import { useProfile } from "./lib/useProfile";
import LoginPage from "./pages/LoginPage";
import OnboardingPage from "./pages/OnboardingPage";
import Shell from "./components/Shell";
import DashboardPage from "./pages/DashboardPage";
import IngresoPage from "./pages/IngresoPage";
import ComingSoonPage from "./pages/ComingSoonPage";

// Las que todavía no tienen pantalla real conectada a Supabase.
// Se van reemplazando una por una en los próximos pasos.
const comingSoon = {
  "/calendario": ["Calendario", "Todos los trabajos del mes de un vistazo."],
  "/inventario": ["Inventario general", "Stock por producto, lote, depósito y estado."],
  "/reservas": ["Reservas", "Equipo comprometido para cada evento, propio o subcontratado."],
  "/preparacion": ["Preparación de pedido", "Asignación óptima de lotes y series."],
  "/transporte": ["Plan de carga", "Peso real y asignación de vehículos."],
  "/vehiculos": ["Vehículos", "Kilómetros, viajes y mantenimiento de la flota."],
  "/retorno": ["Retorno de evento", "Inspección de equipo al volver."],
  "/taller": ["Reparación", "Ticket de taller, incluye selección de gabinete y repuestos."],
  "/reportes": ["Reportes", "Fallas por zona, rentabilidad y valor del stock."],
  "/clientes": ["Clientes", "Historial e ingresos por cliente."],
  "/colaboradores": ["Colaboradores", "Subcontratistas para cubrir faltantes de stock."],
  "/personal": ["Personal", "Empleados fijos y colaboradores eventuales."],
  "/proveedores": ["Proveedores", "Registro e historial de compras."],
  "/configuracion": ["Configuración", "Empresa, módulos habilitados y usuarios."],
};

function ProtectedApp({ session, profile }) {
  return (
    <Shell session={session} profile={profile}>
      <Routes>
        <Route path="/" element={<DashboardPage />} />
        <Route path="/dashboard" element={<DashboardPage />} />
        <Route path="/ingreso" element={<IngresoPage />} />
        {Object.entries(comingSoon).map(([path, [title, description]]) => (
          <Route key={path} path={path} element={<ComingSoonPage title={title} description={description} />} />
        ))}
        <Route path="*" element={<Navigate to="/dashboard" replace />} />
      </Routes>
    </Shell>
  );
}

export default function App() {
  const [session, setSession] = useState(hasSupabase ? undefined : { user: { email: "demo@stageops.app" }, demo: true });
  const { profile, loading: profileLoading } = useProfile(session);

  useEffect(() => {
    if (!hasSupabase) return;
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((_e, next) => setSession(next));
    return () => listener.subscription.unsubscribe();
  }, []);

  if (hasSupabase && session === undefined) return <div className="center-screen">Cargando StageOPS…</div>;
  if (!session) return <LoginPage />;
  if (hasSupabase && profileLoading) return <div className="center-screen">Cargando perfil…</div>;
  if (hasSupabase && !profile?.organization_id) return <OnboardingPage session={session} />;

  return <ProtectedApp session={session} profile={profile} />;
}
