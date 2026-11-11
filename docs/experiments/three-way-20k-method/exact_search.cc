// Equivalent search kernel for the 20x20 elimination experiment.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace {
constexpr int cells = 400, win = 401, infinity = 402;
using Board = std::array<uint8_t, cells>;
struct Neighborhood {
  int n = 0;
  uint16_t pos[8]{};
};
struct Rules {
  Neighborhood nb[cells]{};
  uint8_t next[3][256]{};
  Rules() {
    for (int i = 0; i < cells; ++i)
      for (int dr = -1; dr <= 1; ++dr)
        for (int dc = -1; dc <= 1; ++dc) {
          int r = i / 20 + dr, c = i % 20 + dc;
          if ((dr || dc) && r >= 0 && r < 20 && c >= 0 && c < 20)
            nb[i].pos[nb[i].n++] = r * 20 + c;
        }
    for (int s = 0; s < 3; ++s)
      for (int packed = 0; packed < 256; ++packed) {
        int b = packed & 15, w = packed >> 4, total = b + w;
        next[s][packed] =
            s ? ((total == 2 || total == 3) ? s : 0) : (total == 3 ? (b > w ? 1 : 2) : 0);
      }
  }
};
const Rules rules;
struct Patch {
  uint16_t changes[9];
  uint8_t n;
  int8_t db, dw;
  uint32_t hash;
  void add(int i, int old, int value) {
    uint16_t code = 3 * i + value;
    changes[n++] = code;
    hash = (hash ^ uint32_t(code + 1)) * 16777619u;
    db += (value == 1) - (old == 1);
    dw += (value == 2) - (old == 2);
  }
  bool same(const Patch& p) const {
    return n == p.n && std::memcmp(changes, p.changes, n * sizeof(uint16_t)) == 0;
  }
};
struct Candidate {
  uint16_t place;
  int16_t score;
  bool terminal;
};
struct Exhausted {};
struct Children {
  Board base;
  Patch patches[cells]{};
  Candidate children[cells];
  int n = 0, legal = 0;
  Children(const Board& board, int side, int root, int& used, int budget) {
    if (used >= budget)
      throw Exhausted{};
    std::array<uint8_t, cells> counts{};
    for (int i = 0; i < cells; ++i)
      if (board[i]) {
        const auto& nb = rules.nb[i];
        int amount = board[i] == 1 ? 1 : 16;
        for (int k = 0; k < nb.n; ++k)
          counts[nb.pos[k]] += amount;
      }
    int baseB = 0, baseW = 0;
    int add = side == 1 ? 1 : 16;
    for (int i = 0; i < cells; ++i) {
      int current = board[i], count = counts[i], old = rules.next[current][count];
      base[i] = old;
      baseB += old == 1;
      baseW += old == 2;
      if (!current) {
        ++legal;
        int value = rules.next[side][count];
        if (value != old)
          patches[i].add(i, old, value);
      }
      int value = rules.next[current][count + add];
      if (value != old) {
        const auto& nb = rules.nb[i];
        for (int k = 0; k < nb.n; ++k) {
          int j = nb.pos[k];
          if (!board[j])
            patches[j].add(i, old, value);
        }
      }
    }
    std::array<uint16_t, 1024> seen{};
    for (int i = 0; i < cells; ++i)
      if (!board[i]) {
        const Patch& p = patches[i];
        unsigned k = p.hash & 1023u;
        while (seen[k] && !p.same(patches[seen[k] - 1]))
          k = (k + 1) & 1023u;
        if (seen[k])
          continue;
        seen[k] = i + 1;
        int b = baseB + p.db, w = baseW + p.dw;
        bool terminal = b == 0 || w == 0 || b + w == cells;
        int utility = terminal ? (b > 0 && !w ? win : w > 0 && !b ? -win : 0) : b - w;
        children[n++] = {uint16_t(i), int16_t(root == 1 ? utility : -utility), terminal};
        ++used;
        // Dart stops before probing the iterator again, even when all remaining
        // legal coordinates might be duplicates of an existing successor.
        if (used == budget && n < legal)
          throw Exhausted{};
      }
  }
  Board materialize(int place) const {
    Board out = base;
    const auto& p = patches[place];
    for (int i = 0; i < p.n; ++i) {
      int c = p.changes[i];
      out[c / 3] = c % 3;
    }
    return out;
  }
  void order(bool maximize) {
    std::sort(children, children + n, [maximize](auto a, auto b) {
      if (a.score != b.score)
        return maximize ? a.score > b.score : a.score < b.score;
      return a.place < b.place;
    });
  }
};
struct Key {
  Board board;
  int side, depth, full;
  bool operator==(const Key& o) const {
    return side == o.side && depth == o.depth && full == o.full && board == o.board;
  }
};
struct Hash {
  size_t operator()(const Key& k) const {
    uint64_t h = uint64_t(k.side * 4096 + k.depth * 64 + k.full);
    for (int i = 0; i < cells; i += 8) {
      uint64_t word;
      std::memcpy(&word, k.board.data() + i, 8);
      h = (h ^ word) * 0x9e3779b185ebca87ULL;
    }
    return size_t(h ^ (h >> 32));
  }
};
struct Entry {
  int value, bound;
};

struct Search {
  int root, cap, prefix, width, budget;
  const uint32_t* ties;
  int used = 0, nodes = 0, hits = 0, cutoffs = 0, visited = 0, completed = 0, attempted = 0,
      bestMove = -1, score = 0;
  std::unordered_map<Key, Entry, Hash> tt;
  Search(int side, int cap_, int prefix_, int width_, int budget_, const uint32_t* ties_)
      : root(side), cap(cap_), prefix(prefix_), width(width_), budget(budget_), ties(ties_) {}
  int descend(const Children& c, Candidate child, int side, int depth, int ply, int alpha,
              int beta) {
    ++nodes;
    visited = std::max(visited, ply);
    if (!depth || child.terminal)
      return child.score;
    return visit(c.materialize(child.place), side, depth, ply, alpha, beta);
  }
  int visit(const Board& board, int side, int depth, int ply, int alpha, int beta) {
    Key key{board, side, depth, width >= cells ? depth : std::clamp(prefix - ply, 0, depth)};
    auto found = tt.find(key);
    if (found != tt.end()) {
      auto e = found->second;
      if (e.bound == 0 || (e.bound == 1 && e.value > beta) ||
          (e.bound == -1 && e.value < alpha)) {
        ++hits;
        return e.value;
      }
    }
    Children c(board, side, root, used, budget);
    bool maximize = side == root;
    c.order(maximize);
    int count = ply < prefix ? c.n : std::min(width, c.n), a0 = alpha, b0 = beta,
        value = maximize ? -infinity : infinity;
    if (depth == 1) {
      // Every child is a leaf and sorted by its exact leaf utility.
      value = c.children[0].score;
      bool cut = (maximize ? std::max(alpha, value) : alpha) >
                 (maximize ? beta : std::min(beta, value));
      nodes += cut ? 1 : count;
      cutoffs += cut;
      visited = std::max(visited, ply + 1);
    } else {
      for (int i = 0; i < count; ++i) {
        int v = descend(c, c.children[i], 3 - side, depth - 1, ply + 1, alpha, beta);
        if (maximize) {
          value = std::max(value, v);
          alpha = std::max(alpha, value);
        } else {
          value = std::min(value, v);
          beta = std::min(beta, value);
        }
        if (alpha > beta) {
          ++cutoffs;
          break;
        }
      }
    }
    if (tt.size() < 10000 || tt.find(key) != tt.end())
      tt[key] = {value, value < a0 ? -1 : value > b0 ? 1 : 0};
    return value;
  }
  void run(const Board& b) {
    try {
      for (int d = 1; d <= cap; ++d) {
        attempted = d;
        Children c(b, root, root, used, budget);
        c.order(true);
        for (int i = 1; i < c.n; ++i)
          if (c.children[i].place == bestMove) {
            std::rotate(c.children, c.children + i, c.children + i + 1);
            break;
          }
        int val = -infinity;
        std::array<int, cells> tied;
        int count = 0;
        for (int i = 0; i < c.n; ++i) {
          auto child = c.children[i];
          int v = descend(c, child, 3 - root, d - 1, 1, val, infinity);
          if (v > val) {
            val = v;
            count = 0;
          }
          if (v == val)
            tied[count++] = child.place;
        }
        std::sort(tied.begin(), tied.begin() + count);
        bestMove = tied[ties[d - 1] % count];
        score = val;
        completed = d;
      }
    } catch (const Exhausted&) {
    }
  }
};
}  // namespace
// Caller owns input/output storage; there is no shared per-decision state.
extern "C" void choose(const uint8_t* cellsIn, const uint32_t* ties, int32_t* out, int side,
                       int cap, int prefix, int width, int budget) {
  Board b;
  std::memcpy(b.data(), cellsIn, cells);
  Search s(side, cap, prefix, width, budget, ties);
  s.run(b);
  int result[] = {s.bestMove, s.score, s.completed, s.attempted, s.visited,
                  s.used,     s.nodes, s.hits,      s.cutoffs,   s.used == budget};
  std::copy(result, result + 10, out);
}
