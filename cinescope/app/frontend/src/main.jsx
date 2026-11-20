import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react'
import { createRoot } from 'react-dom/client'
import {
  HashRouter,
  Link,
  NavLink,
  Route,
  Routes,
  useNavigate,
  useParams,
} from 'react-router-dom'
import * as echarts from 'echarts'
import {
  Activity,
  Clapperboard,
  Cpu,
  Moon,
  Play,
  Server,
  Sun,
} from 'lucide-react'
import tmdbLogo from './assets/tmdb-logo.svg'
import './styles.css'

const get = async (path) => {
  const response = await fetch(`/api${path}`)

  const payload = await response.json().catch(() => null)

  if (!response.ok) {
    throw new Error(payload?.detail || `${response.status} ${path}`)
  }

  return payload
}

const fmt = (n, d = 0) =>
  n == null
    ? '–'
    : Number(n).toLocaleString(undefined, {
        minimumFractionDigits: d,
        maximumFractionDigits: d,
      })

const colors = [
  '#d946ef',
  '#818cf8',
  '#2dd4bf',
  '#f59e0b',
  '#fb7185',
  '#60a5fa',
  '#a3e635',
  '#f97316',
]

function useApi(path, interval = 0) {
  const [state, setState] = useState({
    data: null,
    error: null,
  })

  useEffect(() => {
    let live = true

    const load = () => {
      get(path)
        .then((data) => {
          if (live) {
            setState({
              data,
              error: null,
            })
          }
        })
        .catch((error) => {
          if (live) {
            setState({
              data: null,
              error: String(error),
            })
          }
        })
    }

    load()

    const id = interval ? setInterval(load, interval) : 0

    return () => {
      live = false
      clearInterval(id)
    }
  }, [path, interval])

  return state
}

const ThemeContext = createContext(true)

function Chart({ option, height = 320 }) {
  const node = useRef(null)
  const dark = useContext(ThemeContext)

  useEffect(() => {
    const chart = echarts.init(
      node.current,
      dark ? 'dark' : null,
    )

    chart.setOption({
      backgroundColor: 'transparent',
      ...option,
    })

    const observer = new ResizeObserver(() => chart.resize())
    observer.observe(node.current)

    return () => {
      observer.disconnect()
      chart.dispose()
    }
  }, [option, dark])

  return <div ref={node} style={{ height }} />
}

function Card({ title, children, className = '' }) {
  return (
    <section
      className={`rounded-2xl border border-slate-200 bg-white p-5 shadow-sm dark:border-slate-800 dark:bg-slate-900 ${className}`}
    >
      {title && (
        <h3 className="mb-3 text-xs font-bold uppercase tracking-wider text-slate-500">
          {title}
        </h3>
      )}

      {children}
    </section>
  )
}

function Load({ state, children }) {
  if (state.error) {
    return (
      <Card>
        <p className="text-red-500">Could not load: {state.error}</p>
      </Card>
    )
  }

  if (!state.data) {
    return (
      <Card>
        <div className="h-48 animate-pulse rounded-xl bg-slate-200 dark:bg-slate-800" />
      </Card>
    )
  }

  return children(state.data)
}

const Bar = ({
  rows,
  label,
  value,
  color = '#d946ef',
}) => (
  <Chart
    option={{
      tooltip: {
        trigger: 'axis',
      },
      grid: {
        left: 55,
        right: 20,
        top: 18,
        bottom: 55,
      },
      xAxis: {
        type: 'category',
        data: rows.map(label),
        axisLabel: {
          rotate: 35,
        },
      },
      yAxis: {
        type: 'value',
      },
      series: [
        {
          type: 'bar',
          data: rows.map(value),
          itemStyle: {
            color,
            borderRadius: [5, 5, 0, 0],
          },
        },
      ],
    }}
  />
)


function MoviePoster({ movieId, title, data }) {
  const [failed, setFailed] = useState(false)

  const path = data?.[String(movieId)]?.poster

  if (!path || !path.startsWith('/') || failed) {
    return (
      <div className="flex aspect-[2/3] w-24 shrink-0 items-center justify-center rounded-lg bg-slate-200 p-2 text-center text-xs text-slate-500 dark:bg-slate-700">
        No poster
      </div>
    )
  }

  return (
    <img
      src={`https://image.tmdb.org/t/p/w342${path}`}
      alt={`Poster for ${title}`}
      loading="lazy"
      onError={() => setFailed(true)}
      className="aspect-[2/3] w-24 shrink-0 rounded-lg bg-slate-200 object-cover dark:bg-slate-700"
    />
  )
}

function Home() {
  const overview = useApi('/overview')
  const genres = useApi('/genres')
  const top = useApi('/top')
  const cluster = useApi('/cluster/summary', 5000)
  const posters = useApi('/posters')

  return (
    <div className="space-y-7">
      <section className="rounded-3xl bg-gradient-to-br from-fuchsia-600 via-indigo-600 to-cyan-500 p-9 text-white shadow-xl">
        <p className="text-xs font-bold tracking-[.2em] text-white/70">
          CINESCOPE
        </p>

        <h1 className="mt-2 text-4xl font-black tracking-tight md:text-5xl">
          Movie ratings, analyzed at scale.
        </h1>

        <p className="mt-3 max-w-2xl text-white/85">
          Spark on YARN and Hadoop MapReduce work across two DataNode /
          NodeManager containers, with results checked for agreement.
        </p>

        <div className="mt-6 flex flex-wrap gap-3">
          <Link
            to="/genres"
            className="rounded-lg bg-white px-4 py-2 font-bold text-indigo-700"
          >
            Explore genres
          </Link>

          <Link
            to="/cluster"
            className="rounded-lg border border-white/50 px-4 py-2 font-bold"
          >
            Inspect cluster
          </Link>
        </div>
      </section>

      <Load state={overview}>
        {(o) => (
          <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
            {[
              ['Ratings', o.ratings],
              ['Movies', o.movies_rated],
              ['Users', o.users],
              ['Years', o.last_year - o.first_year + 1],
              ['Avg rating', fmt(o.avg_rating, 2)],
            ].map(([label, value]) => (
              <Card key={label}>
                <div className="text-2xl font-black">
                  {typeof value === 'number' ? fmt(value) : value}
                </div>

                <div className="text-xs uppercase tracking-wider text-slate-500">
                  {label}
                </div>
              </Card>
            ))}
          </div>
        )}
      </Load>

      <div className="grid gap-6 lg:grid-cols-3">
        <Card
          title="Average rating by genre"
          className="lg:col-span-2"
        >
          <Load state={genres}>
            {(rows) => (
              <Chart
                height={380}
                option={{
                  tooltip: {
                    trigger: 'axis',
                  },
                  grid: {
                    left: 100,
                    right: 40,
                    top: 20,
                    bottom: 20,
                  },
                  xAxis: {
                    type: 'value',
                    min: 2.5,
                    max: 5,
                  },
                  yAxis: {
                    type: 'category',
                    data: [...rows]
                      .sort((a, b) => a.avg_rating - b.avg_rating)
                      .map((x) => x.genre),
                  },
                  series: [
                    {
                      type: 'bar',
                      data: [...rows]
                        .sort((a, b) => a.avg_rating - b.avg_rating)
                        .map((x, i) => ({
                          value: x.avg_rating,
                          itemStyle: {
                            color: colors[i % colors.length],
                          },
                        })),
                      label: {
                        show: true,
                        position: 'right',
                      },
                    },
                  ],
                }}
              />
            )}
          </Load>
        </Card>

        <Card title="Cluster">
          <div className="text-4xl font-black text-fuchsia-500">
            {cluster.data
              ? `${cluster.data.activeNodes}/${cluster.data.totalNodes}`
              : '…'}
          </div>

          <p className="mt-1 text-sm text-slate-500">
            active YARN worker nodes
          </p>

          <Link
            className="mt-5 inline-block text-sm font-bold text-fuchsia-500"
            to="/cluster"
          >
            Live status →
          </Link>
        </Card>
      </div>

      
      <Card title="Top films by weighted rating">
        <Load state={top}>
          {(rows) => (
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-5">
              {rows.slice(0, 10).map((m, i) => (
                <div
                  key={m.movieId}
                  className="flex gap-3 rounded-xl bg-slate-100 p-3 dark:bg-slate-800"
                >
                  <MoviePoster
                    movieId={m.movieId}
                    title={m.title}
                    data={posters.data}
                  />

                  <div className="min-w-0 flex-1">
                    <span className="text-xs font-bold text-fuchsia-500">
                      #{i + 1}
                    </span>

                    <div className="mt-1 truncate font-semibold" title={m.title}>
                      {m.title}
                    </div>

                    <div className="text-sm text-slate-500">
                      ★ {fmt(m.avg, 2)} · {fmt(m.n)} votes
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </Load>
      </Card>

    </div>
  )
}

function Genres() {
  const data = useApi('/genres')
  const nav = useNavigate()

  return (
    <div className="space-y-6">
      <h1 className="title">Genre Explorer</h1>

      <Load state={data}>
        {(rows) => (
          <>
            <div className="grid gap-6 lg:grid-cols-2">
              <Card title="Popularity vs. quality">
                <Chart
                  height={360}
                  option={{
                    tooltip: {
                      formatter: (p) =>
                        `${p.data.name}<br/>★ ${p.data.value[1]} · ${fmt(p.data.value[0])} ratings`,
                    },
                    grid: {
                      left: 60,
                      right: 20,
                      top: 15,
                      bottom: 45,
                    },
                    xAxis: {
                      type: 'log',
                      name: 'ratings',
                      nameLocation: 'middle',
                      nameGap: 28,
                    },
                    yAxis: {
                      type: 'value',
                      scale: true,
                      name: 'average',
                    },
                    series: [
                      {
                        type: 'scatter',
                        data: rows.map((r, i) => ({
                          name: r.genre,
                          value: [r.ratings, r.avg_rating, r.movies],
                          itemStyle: {
                            color: colors[i % colors.length],
                          },
                        })),
                        symbolSize: (v) =>
                          Math.max(15, Math.sqrt(v[2]) / 3),
                      },
                    ],
                  }}
                />
              </Card>

              <Card title="4-star-or-higher share">
                <Bar
                  rows={rows}
                  label={(r) => r.genre}
                  value={(r) => r.pct_4plus}
                  color="#2dd4bf"
                />
              </Card>
            </div>

            <Card title="Scorecard">
              <div className="overflow-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr>
                      <th>Genre</th>
                      <th>Ratings</th>
                      <th>Movies</th>
                      <th>Average</th>
                      <th>Std dev</th>
                      <th>Median</th>
                      <th>4★+ %</th>
                    </tr>
                  </thead>

                  <tbody>
                    {[...rows]
                      .sort((a, b) => b.avg_rating - a.avg_rating)
                      .map((r) => (
                        <tr
                          key={r.genre}
                          onClick={() =>
                            nav(`/genres/${encodeURIComponent(r.genre)}`)
                          }
                          className="cursor-pointer border-t border-slate-200 hover:bg-fuchsia-500/10 dark:border-slate-800"
                        >
                          <td className="py-2 font-semibold">{r.genre}</td>
                          <td>{fmt(r.ratings)}</td>
                          <td>{fmt(r.movies)}</td>
                          <td>{fmt(r.avg_rating, 3)}</td>
                          <td>{fmt(r.std_rating, 2)}</td>
                          <td>{fmt(r.median, 1)}</td>
                          <td>{fmt(r.pct_4plus, 1)}</td>
                        </tr>
                      ))}
                  </tbody>
                </table>
              </div>
            </Card>
          </>
        )}
      </Load>
    </div>
  )
}

function GenreDetail() {
  const { name: encodedName } = useParams()
  const name = decodeURIComponent(encodedName)
  const state = useApi(`/genres/${encodeURIComponent(name)}`)

  return (
    <div className="space-y-6">
      <Link className="text-sm text-fuchsia-500" to="/genres">
        ← all genres
      </Link>

      <h1 className="title">{name}</h1>

      <Load state={state}>
        {(data) => (
          <>
            <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
              {[
                ['Ratings', data.summary?.ratings],
                ['Movies', data.summary?.movies],
                ['Average', fmt(data.summary?.avg_rating, 3)],
                ['Std dev', fmt(data.summary?.std_rating, 2)],
                ['4★+', fmt(data.summary?.pct_4plus, 1) + '%'],
              ].map(([k, v]) => (
                <Card key={k}>
                  <div className="text-2xl font-black">{fmt(v)}</div>

                  <div className="text-xs uppercase text-slate-500">
                    {k}
                  </div>
                </Card>
              ))}
            </div>

            <div className="grid gap-6 lg:grid-cols-2">
              <Card title="Rating distribution">
                <Bar
                  rows={data.hist}
                  label={(x) => x.rating}
                  value={(x) => x.n}
                  color="#818cf8"
                />
              </Card>

              <Card title="Top 10 weighted ratings">
                <ol className="space-y-2">
                  {data.top.map((x) => (
                    <li
                      key={x.movieId}
                      className="flex justify-between border-b border-slate-200 py-2 dark:border-slate-800"
                    >
                      <span>
                        {x.rk}. {x.title}
                      </span>

                      <b>★ {fmt(x.wr, 2)}</b>
                    </li>
                  ))}
                </ol>
              </Card>
            </div>
          </>
        )}
      </Load>
    </div>
  )
}

function TimeMachine() {
  const state = useApi('/trends')

  return (
    <div className="space-y-6">
      <h1 className="title">Time Machine</h1>

      <Load state={state}>
        {(data) => {
          const years = [
            ...new Set(data.genre_year.map((x) => x.rating_year)),
          ].sort()

          const genres = [
            ...new Set(data.genre_year.map((x) => x.genre)),
          ]

          return (
            <>
              <Card title="Ratings by genre over time">
                <Chart
                  height={430}
                  option={{
                    tooltip: {
                      trigger: 'axis',
                    },
                    legend: {
                      type: 'scroll',
                    },
                    grid: {
                      left: 55,
                      right: 20,
                      top: 55,
                      bottom: 40,
                    },
                    xAxis: {
                      type: 'category',
                      data: years,
                    },
                    yAxis: {
                      type: 'value',
                    },
                    series: genres.map((g, i) => ({
                      name: g,
                      type: 'line',
                      showSymbol: false,
                      smooth: true,
                      itemStyle: {
                        color: colors[i % colors.length],
                      },
                      data: years.map(
                        (y) =>
                          (
                            data.genre_year.find(
                              (x) =>
                                x.genre === g && x.rating_year === y,
                            ) || {}
                          ).ratings || 0,
                      ),
                    })),
                  }}
                />
              </Card>

              <Card title="Average rating by release decade">
                <Chart
                  height={460}
                  option={{
                    tooltip: {
                      position: 'top',
                    },
                    grid: {
                      left: 95,
                      right: 30,
                      top: 25,
                      bottom: 60,
                    },
                    xAxis: {
                      type: 'category',
                      data: [
                        ...new Set(
                          data.genre_decade.map((x) => x.decade),
                        ),
                      ]
                        .sort()
                        .map((x) => x + 's'),
                    },
                    yAxis: {
                      type: 'category',
                      data: genres,
                    },
                    visualMap: {
                      min: 2.5,
                      max: 4.5,
                      calculable: true,
                      orient: 'horizontal',
                      left: 'center',
                      bottom: 0,
                      inRange: {
                        color: ['#7f1d1d', '#f59e0b', '#10b981'],
                      },
                    },
                    series: [
                      {
                        type: 'heatmap',
                        data: data.genre_decade.map((x) => [
                          [
                            ...new Set(
                              data.genre_decade.map((a) => a.decade),
                            ),
                          ]
                            .sort()
                            .indexOf(x.decade),
                          genres.indexOf(x.genre),
                          x.avg_rating,
                        ]),
                      },
                    ],
                  }}
                />
              </Card>
            </>
          )
        }}
      </Load>
    </div>
  )
}


function Movies() {
  const [q, setQ] = useState('')
  const [rows, setRows] = useState([])

  const posters = useApi('/posters')

  useEffect(() => {
    const id = setTimeout(() => {
      if (q.length <= 1) {
        setRows([])
        return
      }

      get('/movies/search?q=' + encodeURIComponent(q))
        .then(setRows)
        .catch(() => setRows([]))
    }, 300)

    return () => clearTimeout(id)
  }, [q])

  return (
    <div className="space-y-6">
      <h1 className="title">Movie Explorer</h1>

      <Card>
        <input
          className="w-full rounded-xl border border-slate-300 bg-transparent p-3 outline-none focus:border-fuchsia-500 dark:border-slate-700"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search any title..."
        />

        <div className="mt-4 grid gap-3 md:grid-cols-2">
          {rows.map((m) => (
            <div
              key={m.movieId}
              className="flex gap-3 rounded-xl bg-slate-100 p-4 dark:bg-slate-800"
            >
              <MoviePoster
                movieId={m.movieId}
                title={m.title}
                data={posters.data}
              />

              <div className="min-w-0 flex-1">
                <b>{m.title}</b>

                <div className="mt-2 text-sm text-slate-500">
                  ★ {fmt(m.avg, 2)} · {fmt(m.n)} ratings · {m.genres}
                </div>
              </div>
            </div>
          ))}
        </div>
      </Card>
    </div>
  )
}

function Insights() {
  const state = useApi('/insights')

  return (
    <div className="space-y-6">
      <h1 className="title">Insights</h1>

      <Load state={state}>
        {(d) => (
          <div className="grid gap-6 lg:grid-cols-2">
            <Card title="All ratings by star value">
              <Bar
                rows={d.rating_hist}
                label={(x) => x.rating}
                value={(x) => x.n}
                color="#818cf8"
              />
            </Card>

            <Card title="Ratings per year">
              <Bar
                rows={d.year_volume}
                label={(x) => x.rating_year}
                value={(x) => x.ratings}
                color="#f59e0b"
              />
            </Card>

            <Card title="User activity">
              <Bar
                rows={d.user_activity}
                label={(x) => x.bucket}
                value={(x) => x.users}
                color="#2dd4bf"
              />
            </Card>

            <Card title="Generous vs. harsh raters">
              <Bar
                rows={d.user_avg_hist}
                label={(x) => x.bin}
                value={(x) => x.users}
                color="#fb7185"
              />
            </Card>
          </div>
        )}
      </Load>
    </div>
  )
}

function Cluster() {
  const summary = useApi('/cluster/summary', 4000)
  const nodes = useApi('/cluster/nodes', 4000)
  const hdfs = useApi('/cluster/hdfs', 12000)
  const apps = useApi('/cluster/apps', 5000)
  const validation = useApi('/validation', 20000)
  const status = useApi('/run/status', 1500)

  const [runError, setRunError] = useState(null)

  const run = async () => {
    setRunError(null)

    try {
      const response = await fetch('/api/run', {
        method: 'POST',
      })

      const payload = await response.json().catch(() => null)

      if (!response.ok) {
        throw new Error(
          payload?.detail || `${response.status} /api/run`,
        )
      }
    } catch (error) {
      setRunError(
        error instanceof Error ? error.message : String(error),
      )
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="title">Cluster & Jobs</h1>

        {validation.data?.match !== undefined && (
          <span
            className={`rounded-full px-3 py-1 text-sm font-bold ${
              validation.data.match
                ? 'bg-emerald-500/15 text-emerald-500'
                : 'bg-red-500/15 text-red-500'
            }`}
          >
            {validation.data.match
              ? '✓ Spark = MapReduce'
              : '✕ outputs differ'}
          </span>
        )}
      </div>

      {/* Cluster summary and scorecard execution */}

      <Load state={summary}>
        {(s) => (
          <div className="grid gap-3 md:grid-cols-3">
            <Card>
              <Server className="text-fuchsia-500" />

              <b className="mt-2 block">master</b>

              <p className="text-sm text-slate-500">
                NameNode · ResourceManager · API
              </p>
            </Card>

            <Card>
              <Activity className="text-emerald-500" />

              <div className="mt-2 text-2xl font-black">
                {s.activeNodes}/{s.totalNodes}
              </div>

              <p className="text-sm text-slate-500">
                active YARN worker nodes
              </p>

              <p className="mt-1 text-xs text-slate-500">
                {s.lostNodes} lost nodes
              </p>
            </Card>

            <Card>
              <button
                disabled={status.data?.state === 'running'}
                onClick={run}
                className="flex items-center gap-2 rounded-lg bg-fuchsia-500 px-3 py-2 font-bold text-white disabled:cursor-not-allowed disabled:opacity-50"
              >
                <Play size={16} />
                Run scorecard
              </button>

              <p className="mt-3 text-sm text-slate-500">
                {status.data?.state || 'idle'}
              </p>

              {runError && (
                <p className="mt-2 text-sm text-red-500">
                  {runError}
                </p>
              )}
            </Card>
          </div>
        )}
      </Load>

      {/* YARN NodeManager health */}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card title="YARN NodeManager health">
          <Load state={nodes}>
            {(rows) =>
              rows.length === 0 ? (
                <p className="text-sm text-slate-500">
                  No NodeManagers are currently reported by YARN.
                </p>
              ) : (
                <div className="space-y-3">
                  {rows.map((n) => (
                    <div
                      key={n.host}
                      className="flex justify-between rounded-xl bg-slate-100 p-3 dark:bg-slate-800"
                    >
                      <span className="flex items-center gap-2 font-bold">
                        <Cpu size={16} />
                        {n.host}
                      </span>

                      <span className="text-sm text-slate-500">
                        {n.state} · {n.containers} containers ·{' '}
                        {fmt(n.memUsedMB)}/
                        {fmt(n.memUsedMB + n.memAvailMB)} MB
                      </span>
                    </div>
                  ))}
                </div>
              )
            }
          </Load>
        </Card>

        {/* HDFS DataNode and replica evidence */}

        <Card title="HDFS DataNode and replica evidence">
          <Load state={hdfs}>
            {(data) => (
              <>
                <div className="text-3xl font-black text-cyan-500">
                  {fmt(data.datanodes)}
                </div>

                <p className="text-sm text-slate-500">
                  live HDFS DataNodes ·{' '}
                  {data.total_blocks ?? '–'} ratings.csv blocks
                </p>

                {data.blocks.length === 0 ? (
                  <p className="mt-4 text-sm text-slate-500">
                    No DataNode block locations were reported.
                  </p>
                ) : (
                  <ul className="mt-4 list-disc pl-5 text-sm">
                    {data.blocks.map((b) => (
                      <li key={b.node}>
                        {b.node}: {b.replicas} block replica locations
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </Load>
        </Card>
      </div>

      {/* Recent YARN applications */}

      <Card title="Recent YARN applications">
        <Load state={apps}>
          {(rows) =>
            rows.length === 0 ? (
              <p className="text-sm text-slate-500">
                No YARN applications were returned by the ResourceManager.
              </p>
            ) : (
              <div className="overflow-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Type</th>
                      <th>State</th>
                      <th>Result</th>
                      <th>Seconds</th>
                    </tr>
                  </thead>

                  <tbody>
                    {rows.map((a) => (
                      <tr
                        key={a.id}
                        className="border-t border-slate-200 dark:border-slate-800"
                      >
                        <td className="py-2">{a.name}</td>
                        <td>{a.type}</td>
                        <td>{a.state}</td>
                        <td>{a.final}</td>
                        <td>{fmt(a.seconds, 1)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          }
        </Load>
      </Card>

      {/* Scorecard execution log */}

      {status.data?.log && (
        <Card title="Scorecard job output">
          <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words text-xs text-slate-600 dark:text-slate-300">
            {status.data.log}
          </pre>
        </Card>
      )}
    </div>
  )
}


function About() {
  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <h1 className="title">About CineScope</h1>

      <Card title="Project">
        <p>
          CineScope analyzes MovieLens ratings on one master and two worker
          containers. The master is the NameNode, ResourceManager, Spark
          driver, API and UI. The workers are DataNode and NodeManager
          services.
        </p>
      </Card>

      <Card title="Dataset citation">
        <p>
          F. Maxwell Harper and Joseph A. Konstan. 2015.
          The MovieLens Datasets: History and Context.
          ACM TiiS 5, 4.
        </p>
      </Card>

      <Card title="TMDB attribution">
        <div className="flex items-center gap-3">
          <a
            href="https://www.themoviedb.org"
            target="_blank"
            rel="noreferrer"
          >
            <img
              src={tmdbLogo}
              alt="TMDB logo"
              className="h-7 w-auto"
            />
          </a>

          <p className="text-sm">
            This product uses the TMDB API but is not
            endorsed or certified by TMDB.
          </p>
        </div>
      </Card>

      <Card title="Scope">
        <p>
          This is a private, unauthenticated teaching cluster.
          Do not expose HDFS, YARN or the API to an untrusted network.
        </p>
      </Card>
    </div>
  )
}

function getInitialDark() {
  try {
    const saved = window.localStorage.getItem('cinescope-theme')

    if (saved === 'dark') return true
    if (saved === 'light') return false
  } catch {}

  return true
}

function App() {
  const [dark, setDark] = useState(getInitialDark)

  useLayoutEffect(() => {
    const root = document.documentElement

    root.classList.toggle('dark', dark)
    root.style.colorScheme = dark ? 'dark' : 'light'

    try {
      window.localStorage.setItem(
        'cinescope-theme',
        dark ? 'dark' : 'light',
      )
    } catch {}
  }, [dark])

  const links = [
    ['/', 'Home'],
    ['/genres', 'Genres'],
    ['/time', 'Time Machine'],
    ['/movies', 'Movies'],
    ['/insights', 'Insights'],
    ['/cluster', 'Cluster'],
    ['/about', 'About'],
  ]

  return (
    <ThemeContext.Provider value={dark}>
      <div className="min-h-screen bg-slate-50 text-slate-900 dark:bg-slate-950 dark:text-slate-100">
        <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/85 backdrop-blur dark:border-slate-800 dark:bg-slate-950/85">
          <div className="mx-auto flex max-w-7xl items-center gap-5 px-4 py-3">
            <Clapperboard className="text-fuchsia-500" />

            <b>CineScope</b>

            <nav className="flex flex-1 gap-1 overflow-auto text-sm">
              {links.map(([to, label]) => (
                <NavLink
                  key={to}
                  end={to === '/'}
                  to={to}
                  className={({ isActive }) =>
                    `whitespace-nowrap rounded-lg px-3 py-1.5 ${
                      isActive
                        ? 'bg-fuchsia-500/15 font-bold text-fuchsia-500'
                        : 'text-slate-500 hover:bg-slate-500/10'
                    }`
                  }
                >
                  {label}
                </NavLink>
              ))}
            </nav>

            <button
              type="button"
              className="rounded-lg p-2 hover:bg-slate-500/10"
              onClick={() => setDark((current) => !current)}
              aria-label="Toggle dark mode"
              aria-pressed={dark}
              title={
                dark
                  ? 'Switch to light mode'
                  : 'Switch to dark mode'
              }
            >
              {dark ? <Sun size={17} /> : <Moon size={17} />}
            </button>
          </div>
        </header>

        <main className="mx-auto max-w-7xl px-4 py-8">
          <Routes>
            <Route path="/" element={<Home />} />
            <Route path="/genres" element={<Genres />} />
            <Route path="/genres/:name" element={<GenreDetail />} />
            <Route path="/time" element={<TimeMachine />} />
            <Route path="/movies" element={<Movies />} />
            <Route path="/insights" element={<Insights />} />
            <Route path="/cluster" element={<Cluster />} />
            <Route path="/about" element={<About />} />
          </Routes>
        </main>
      </div>
    </ThemeContext.Provider>
  )
}

createRoot(document.getElementById('root')).render(
  <HashRouter>
    <App />
  </HashRouter>,
)