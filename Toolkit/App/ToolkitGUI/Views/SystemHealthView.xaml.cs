using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class SystemHealthView : WorkflowViewBase
    {
        public SystemHealthView()
        {
            InitializeComponent();
            Loaded += OnLoaded;
        }

        private void OnLoaded(object sender, System.Windows.RoutedEventArgs e)
        {
            ApplyPendingNavigationContext();
        }

        public void ApplyPendingNavigationContext()
        {
            var context = NavigationService.ConsumePendingContext();
            if (DataContext is SystemHealthViewModel vm)
                vm.ApplyNavigationContext(context);
        }
    }
}
