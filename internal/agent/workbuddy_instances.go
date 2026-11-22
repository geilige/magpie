package agent

// WorkBuddy kept in more than one instance at once: a launcher runs several
// instances of it side by side, each with a config folder of its own under
// one folder, which WORKBUDDY_INSTANCES_ROOT names:
//
//	<root>/instance-2/config/models.json
//	<root>/instance-3/config/models.json
//
// The folder WORKBUDDY_CONFIG_DIR names (~/.workbuddy when it is unset) is
// the workbuddy row; every instance under the root is a row of its own,
// workbuddy#<n> (as another Claude Code folder is claude#<name>), with its
// own models.json to connect and its own list of magpie's models. Without
// the variable there are no rows: a launcher's folder is no path for magpie
// to guess, and a machine with one WorkBuddy has none of this.

import (
	"cmp"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/yetone/magpie/internal/appdir"
	"github.com/yetone/magpie/internal/dirent"
)

// workbuddyInstances are WorkBuddy's other instances, a row each, by
// instance number (2 before 10, not by name). An instance is a folder named
// instance-<n> holding a config folder: models.json needn't be there yet,
// as a new instance has none and connecting one is what writes it.
func workbuddyInstances(home string) []*Agent {
	root := appdir.Getenv("WORKBUDDY_INSTANCES_ROOT")
	if root == "" {
		return nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	// the folder workbuddy(home) writes is no second row for it
	main := filepath.Clean(workbuddy(home).Dir)
	type instance struct {
		num int
		dir string
	}
	var found []instance
	seen := map[int]bool{}
	for _, e := range entries {
		num, ok := workbuddyInstanceNumber(e.Name())
		if !ok || seen[num] || !dirent.IsFolder(root, e) {
			continue
		}
		dir := filepath.Join(root, e.Name(), "config")
		if !isDir(dir) || strings.EqualFold(filepath.Clean(dir), main) {
			continue
		}
		seen[num] = true
		found = append(found, instance{num: num, dir: dir})
	}
	slices.SortFunc(found, func(a, b instance) int { return cmp.Compare(a.num, b.num) })
	out := make([]*Agent, 0, len(found))
	for _, in := range found {
		out = append(out, workbuddyInstance(in.num, in.dir))
	}
	return out
}

// workbuddyInstanceNumber is the n of an instance-<n> folder, false for
// any other name. instance-02 counts as 2: two folders of one number are
// one instance, the first by name (os.ReadDir's order).
func workbuddyInstanceNumber(name string) (int, bool) {
	rest, ok := strings.CutPrefix(strings.ToLower(name), "instance-")
	if !ok || rest == "" {
		return 0, false
	}
	for _, r := range rest {
		if r < '0' || r > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}

// workbuddyInstance is one instance as a row, its name as WorkBuddy's own
// window titles the instance.
//
// The row's id names the instance, so that the window's keys don't collide
// on two rows; what magpie writes is WorkBuddy's all the same. buddyWriteAt
// and buddyIDs compare the agent with "workbuddy" by hand, and given
// workbuddy#2 one would write a new models.json as {"models":[...]}, which
// WorkBuddy reads as no list at all (workbuddy.go). So the row is its own
// and the file is WorkBuddy's: the two closures that carry the id into a
// write, Sync and the provider field's Set, are given the write the
// workbuddy row makes, and the rest (the field's Get and Options,
// ListsModels, the icon, the app bundle) is workbuddyBuild's.
func workbuddyInstance(n int, dir string) *Agent {
	id := fmt.Sprintf("workbuddy#%d", n)
	a := workbuddyBuild(id, fmt.Sprintf("WorkBuddy [%d]", n), dir, nil, workbuddyApp)
	write := func(on bool) error { return workbuddyWrite(a.Path, on) }
	a.Sync = func() error {
		if !workbuddyWired(a.Path) {
			return nil
		}
		return write(true)
	}
	if f := a.Field("provider"); f != nil {
		f.Set = func(v string) error { return write(v != "") }
	}
	// the workbuddy row keeps the command, the names and the requests:
	// this one is found by its folder alone, and its folder is what says
	// it is here (an empty config folder is a new instance, not an absent
	// one), as another Claude Code folder is claudeDirIsClaude's
	a.Aliases, a.UA = nil, nil
	a.detect = func() bool { return isDir(dir) }
	return a
}
