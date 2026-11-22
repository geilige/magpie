package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/yetone/magpie/internal/provider"
)

// WorkBuddy's other instances: a row each, its own models.json, written as
// the file WorkBuddy reads (a bare list, under workbuddy's key).
func TestWorkBuddyInstances(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(home, ".cache"))
	t.Setenv("WORKBUDDY_CONFIG_DIR", "")
	t.Setenv("WORKBUDDY_INSTANCES_ROOT", "")
	if err := provider.Save(provider.Provider{ID: "deepseek", Name: "DeepSeek", Chat: "https://api.deepseek.com/v1", Key: "k", Models: []string{"pro"}}); err != nil {
		t.Fatal(err)
	}

	root := filepath.Join(home, "instances")
	for _, name := range []string{"instance-2", "instance-3", "instance-10"} {
		if err := os.MkdirAll(filepath.Join(root, name, "config"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// a folder with no config in it, and folders that are no instance
	for _, name := range []string{"instance-8", filepath.Join("instance-x", "config"), "notes"} {
		if err := os.MkdirAll(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	// no variable, no rows: magpie guesses no folder
	if got := workbuddyInstances(home); len(got) != 0 {
		t.Fatalf("without WORKBUDDY_INSTANCES_ROOT: %v", ids(got))
	}
	// a root that isn't there is no instance, and no panic
	t.Setenv("WORKBUDDY_INSTANCES_ROOT", filepath.Join(home, "nope"))
	if got := workbuddyInstances(home); len(got) != 0 {
		t.Fatalf("a root that isn't there: %v", ids(got))
	}

	t.Setenv("WORKBUDDY_INSTANCES_ROOT", root)
	as := workbuddyInstances(home)
	want := []struct {
		id   string
		name string
		dir  string
	}{
		{"workbuddy#2", "WorkBuddy [2]", filepath.Join(root, "instance-2", "config")},
		{"workbuddy#3", "WorkBuddy [3]", filepath.Join(root, "instance-3", "config")},
		{"workbuddy#10", "WorkBuddy [10]", filepath.Join(root, "instance-10", "config")},
	}
	if len(as) != len(want) {
		t.Fatalf("instances: %v", ids(as))
	}
	for i, w := range want {
		a := as[i]
		if a.ID != w.id || a.Name != w.name || a.Dir != w.dir || a.Path != filepath.Join(w.dir, "models.json") {
			t.Fatalf("%d: %s %s %s %s", i, a.ID, a.Name, a.Dir, a.Path)
		}
		// a row the Agents page shows: its config folder is there
		if !a.Detected() {
			t.Fatalf("%s: not detected", a.ID)
		}
	}

	// connected, an instance's models.json is the bare list WorkBuddy
	// writes, its entries under the key the workbuddy row's are
	path := as[0].Path
	if err := as[0].Field("provider").Set(magpieID); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) == 0 || b[0] != '[' {
		t.Fatalf("not a bare list: %s", b)
	}
	var ms []map[string]any
	if err := json.Unmarshal(b, &ms); err != nil {
		t.Fatalf("%v\n%s", err, b)
	}
	if len(ms) != 1 || ms[0]["id"] != "deepseek/pro" || ms[0]["vendor"] != magpieID || ms[0]["apiKey"] != agentKey("workbuddy") {
		t.Fatalf("entry: %v", ms)
	}
	if got := as[0].Field("provider").Get(); got != magpieID {
		t.Fatalf("get: %q", got)
	}
	// an instance writes its own file and no other
	if _, err := os.Stat(as[1].Path); err == nil {
		t.Fatalf("instance 3 was written too: %s", as[1].Path)
	}
	// a sync keeps the list, and the default takes magpie's out
	if err := as[0].Sync(); err != nil {
		t.Fatal(err)
	}
	if b, _ = os.ReadFile(path); !strings.Contains(string(b), "deepseek/pro") {
		t.Fatalf("after a sync: %s", b)
	}
	if err := as[0].Field("provider").Set(""); err != nil {
		t.Fatal(err)
	}
	if b, _ = os.ReadFile(path); strings.Contains(string(b), "deepseek/pro") || !strings.HasPrefix(strings.TrimSpace(string(b)), "[") {
		t.Fatalf("after off: %s", b)
	}

	// the registration: the list the window reads holds them too
	var registered []string
	for _, a := range onMachine(home, filepath.Join(home, ".config")) {
		registered = append(registered, a.ID)
	}
	for _, id := range []string{"workbuddy#2", "workbuddy#3", "workbuddy#10"} {
		if !slices.Contains(registered, id) {
			t.Fatalf("%s is not in onMachine: %v", id, registered)
		}
	}

	// the instance WORKBUDDY_CONFIG_DIR names is the workbuddy row already:
	// no second row writes the same file
	t.Setenv("WORKBUDDY_CONFIG_DIR", filepath.Join(root, "instance-3", "config"))
	as = workbuddyInstances(home)
	if len(as) != 2 || as[0].ID != "workbuddy#2" || as[1].ID != "workbuddy#10" {
		t.Fatalf("an instance that is the workbuddy row: %v", ids(as))
	}

	// one number, one instance: instance-02 and instance-2 are one row
	dup := filepath.Join(home, "dup")
	for _, name := range []string{"instance-02", "instance-2"} {
		if err := os.MkdirAll(filepath.Join(dup, name, "config"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("WORKBUDDY_CONFIG_DIR", "")
	t.Setenv("WORKBUDDY_INSTANCES_ROOT", dup)
	if as = workbuddyInstances(home); len(as) != 1 || as[0].ID != "workbuddy#2" || as[0].Dir != filepath.Join(dup, "instance-02", "config") {
		t.Fatalf("two folders of one number: %v", ids(as))
	}
}

func TestWorkBuddyInstanceNumber(t *testing.T) {
	names := []string{"instance-2", "instance-10", "Instance-4", "instance-02", "instance-0", "instance-", "instance-2x", "instances-2", "instance2", ""}
	nums := []int{2, 10, 4, 2, 0, 0, 0, 0, 0, 0}
	oks := []bool{true, true, true, true, false, false, false, false, false, false}
	for i, name := range names {
		n, ok := workbuddyInstanceNumber(name)
		if n != nums[i] || ok != oks[i] {
			t.Errorf("%q: %d %v, want %d %v", name, n, ok, nums[i], oks[i])
		}
	}
}
