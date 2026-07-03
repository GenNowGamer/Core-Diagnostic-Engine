using System.Windows;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class DiagAndRepairView : WorkflowViewBase
    {
        public DiagAndRepairView()
        {
            InitializeComponent();
            Loaded += (_, _) => ApplyPendingNavigationContext();
        }

        public void ApplyPendingNavigationContext()
        {
            if (DataContext is not DiagAndRepairViewModel vm)
                return;

            var context = Services.NavigationService.ConsumePendingContext();
            if (!string.IsNullOrWhiteSpace(context))
                vm.ApplyNavigationContext(context);
        }
    }
}
